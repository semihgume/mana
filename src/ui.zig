const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("c");
const translator = @import("translator.zig");
const state = @import("state.zig");

pub const Request = struct {
    text: []const u8,
    /// Shown instead of a translation, e.g. when nothing was selected.
    problem: ?[]const u8,
    backend: translator.Backend,
    options: translator.Options,
    /// Target language codes offered in the picker after "Auto", in order.
    languages: []const []const u8,
    /// Where a dragged position is remembered; `null`: nowhere.
    position_path: ?[]const u8,
    /// Problems with the config file, shown as a notice below the translation.
    config_problems: []const []const u8,
};

const popup_width = 560;
const max_translation_height = 360;
/// The least the translation keeps on a monitor too small for the full height.
const min_translation_height = 48;
const top_margin = 80;
/// Pointer travel in pixels after which a press on the header becomes a drag.
const drag_threshold = 3;
/// How long (ms) the popup must stay unfocused before it closes.
const focus_settle_time = 200;

/// Display names for language codes in the picker, each in its own language.
const language_names = [_]struct { code: []const u8, name: [:0]const u8 }{
    .{ .code = "tr", .name = "Türkçe" },
    .{ .code = "en", .name = "English" },
    .{ .code = "de", .name = "Deutsch" },
    .{ .code = "fr", .name = "Français" },
    .{ .code = "es", .name = "Español" },
    .{ .code = "it", .name = "Italiano" },
    .{ .code = "pt", .name = "Português" },
    .{ .code = "nl", .name = "Nederlands" },
    .{ .code = "pl", .name = "Polski" },
    .{ .code = "sv", .name = "Svenska" },
    .{ .code = "el", .name = "Ελληνικά" },
    .{ .code = "ru", .name = "Русский" },
    .{ .code = "uk", .name = "Українська" },
    .{ .code = "ar", .name = "العربية" },
    .{ .code = "fa", .name = "فارسی" },
    .{ .code = "hi", .name = "हिन्दी" },
    .{ .code = "ja", .name = "日本語" },
    .{ .code = "ko", .name = "한국어" },
    .{ .code = "zh-CN", .name = "中文" },
    .{ .code = "zh-TW", .name = "繁體中文" },
};

const css =
    \\window.mana-popup { background: none; }
    \\.card {
    \\  margin: 12px;
    \\  padding: 12px 16px 16px;
    \\  border-radius: 12px;
    \\  border: 1px solid alpha(@theme_fg_color, 0.12);
    \\  background-color: @theme_bg_color;
    \\  color: @theme_fg_color;
    \\  box-shadow: 0 3px 10px alpha(black, 0.35);
    \\}
    \\.direction { font-weight: bold; font-size: 0.85em; opacity: 0.7; }
    \\.original { opacity: 0.55; }
    \\.translation { font-size: 1.15em; }
    \\.notice { font-size: 0.85em; opacity: 0.45; }
    \\.error { color: @error_color; }
;

const Popup = struct {
    gpa: Allocator,
    io: Io,
    request: Request,
    // The GTK objects are set in `show` once GTK runs, after the first
    // translation has started; until then nothing may touch them.
    loop: *c.GMainLoop = undefined,
    window: *c.GtkWindow = undefined,
    direction: *c.GtkLabel = undefined,
    translation: *c.GtkLabel = undefined,
    scroller: *c.GtkScrolledWindow = undefined,
    copy_button: *c.GtkButton = undefined,
    language: *c.GtkDropDown = undefined,
    /// The dropdown's list. GtkDropDown has no getter; it is a child widget.
    language_list: ?*c.GtkPopover = undefined,
    /// Widgets a drag may start on: the header row and the card's empty
    /// space, but not the text labels, so text selection keeps working.
    drag_handles: [4]*c.GtkWidget = undefined,
    /// Bumped for every translation request; older results are dropped.
    generation: u32 = 0,
    translated: ?[:0]const u8 = null,
    was_active: bool = false,
    dragging: bool = false,
    /// Layer-shell margins (left, top) the incoming pointer events are
    /// relative to: the ones of the last committed frame.
    drag_base: [2]c_int = .{ 0, 0 },
    /// Window size `keepOnScreen` last checked; any other size is re-checked.
    checked_size: [2]c_int = .{ 0, 0 },
};

/// One translation request. Never freed (the process is short-lived), so a
/// worker that finishes after a newer request started writes to valid memory.
const Job = struct {
    popup: *Popup,
    generation: u32,
    /// `null` applies the smart rule.
    target: ?[]const u8,
    /// Written by the worker thread before it lets `onResult` be scheduled.
    outcome: Outcome = undefined,
    /// Steps still missing before `onResult` may run: the worker finishing,
    /// and `watch`, which is only called once the widgets exist. The step
    /// that comes last schedules it (`stepDone`).
    steps_left: std.atomic.Value(u8) = .init(2),
    /// Set on the main thread once `onResult` has run.
    done: bool = false,
};

const Outcome = union(enum) {
    translated: struct { direction: [:0]const u8, text: [:0]const u8 },
    failed: [:0]const u8,
};

/// Shows the popup and runs the GTK main loop. Exits the process when the
/// popup closes, and with status 1 when the UI cannot be started.
pub fn run(gpa: Allocator, io: Io, request: Request) noreturn {
    show(gpa, io, request) catch |err| {
        // The first translation's worker may be using `gpa` and `io`
        // already: exit instead of returning from `main`.
        std.log.err("{t}", .{err});
        std.process.exit(1);
    };
}

fn show(gpa: Allocator, io: Io, request: Request) !noreturn {
    const popup = try gpa.create(Popup);
    popup.* = .{ .gpa = gpa, .io = io, .request = request };
    // The request needs no widgets, so it runs while GTK starts up; if it
    // cannot be started here, the normal path below tries again.
    const first_job = if (request.problem == null) startJob(popup, request.options.forced_target) catch null else null;

    if (c.gtk_init_check() == 0) return error.CannotOpenDisplay;

    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider, css);
    c.gtk_style_context_add_provider_for_display(
        c.gdk_display_get_default(),
        @ptrCast(provider),
        c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    const window: *c.GtkWindow = @ptrCast(c.gtk_window_new());
    c.gtk_window_set_title(window, "mana");
    c.gtk_widget_add_css_class(widget(window), "mana-popup");
    if (c.gtk_layer_is_supported() != 0) {
        c.gtk_layer_init_for_window(window);
        c.gtk_layer_set_namespace(window, "mana");
        c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
        c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_TOP, 1);
        c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_TOP, top_margin);
        // Where the last drag left it, anchored by the top-left corner as a
        // drag does (`beginMove`). Brought on screen once its monitor and
        // size are known (`keepOnScreen`).
        if (request.position_path) |path| if (state.loadPosition(io, path)) |position| {
            c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_LEFT, 1);
            c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_LEFT, position[0]);
            c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_TOP, position[1]);
        };
        // Position against the whole monitor rather than the area panels
        // leave free, so drag margins match the monitor geometry.
        c.gtk_layer_set_exclusive_zone(window, -1);
        c.gtk_layer_set_keyboard_mode(window, c.GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND);
    } else {
        std.debug.print("warning: the compositor does not support layer-shell; using a normal window\n", .{});
    }

    const card = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8);
    c.gtk_widget_add_css_class(card, "card");
    c.gtk_widget_set_size_request(card, popup_width, -1);
    c.gtk_window_set_child(window, card);

    const header = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    const direction: *c.GtkLabel = @ptrCast(c.gtk_label_new("Translate"));
    c.gtk_label_set_xalign(direction, 0);
    c.gtk_widget_set_hexpand(widget(direction), 1);
    c.gtk_widget_add_css_class(widget(direction), "direction");
    const language = try newLanguagePicker(gpa, request.languages, request.options.forced_target);
    const copy_button: *c.GtkButton = @ptrCast(c.gtk_button_new_with_label("Copy"));
    c.gtk_widget_add_css_class(widget(copy_button), "flat");
    c.gtk_widget_set_sensitive(widget(copy_button), 0);
    c.gtk_box_append(@ptrCast(header), widget(direction));
    c.gtk_box_append(@ptrCast(header), widget(language.dropdown));
    c.gtk_box_append(@ptrCast(header), widget(copy_button));
    c.gtk_box_append(@ptrCast(card), header);

    const original = newWrappingLabel(try previewText(gpa, request.text), "original");
    c.gtk_label_set_lines(original, 3);
    c.gtk_label_set_ellipsize(original, c.PANGO_ELLIPSIZE_END);
    // Empty when nothing was selected; an empty label still takes a line.
    c.gtk_widget_set_visible(widget(original), @intFromBool(request.text.len > 0));
    c.gtk_box_append(@ptrCast(card), widget(original));

    const translation = newWrappingLabel("Translating…", "translation");
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_max_content_height(@ptrCast(scroller), max_translation_height);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), widget(translation));
    c.gtk_box_append(@ptrCast(card), scroller);

    // Started from a shortcut nobody sees stderr, so config problems show here.
    if (request.config_problems.len > 0) {
        const notice = newWrappingLabel(try noticeText(gpa, request.config_problems), "notice");
        c.gtk_box_append(@ptrCast(card), widget(notice));
    }

    // Field by field: a worker may be reading the other fields.
    popup.loop = c.g_main_loop_new(null, 0).?;
    popup.window = window;
    popup.direction = direction;
    popup.translation = translation;
    popup.scroller = @ptrCast(scroller);
    popup.copy_button = copy_button;
    popup.language = language.dropdown;
    popup.language_list = language.list;
    popup.drag_handles = .{ widget(window), card, header, widget(direction) };

    const keys = c.gtk_event_controller_key_new();
    // Capture phase, so Ctrl+C reaches us before the selectable label handles it.
    c.gtk_event_controller_set_propagation_phase(keys, c.GTK_PHASE_CAPTURE);
    connect(keys, "key-pressed", &onKeyPressed, popup);
    c.gtk_widget_add_controller(widget(window), keys);
    const drag = c.gtk_gesture_drag_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(drag), c.GTK_PHASE_CAPTURE);
    connect(drag, "drag-begin", &onPress, popup);
    connect(drag, "drag-update", &onDragUpdate, popup);
    connect(drag, "drag-end", &onDragEnd, popup);
    c.gtk_widget_add_controller(widget(window), @ptrCast(drag));
    connect(window, "notify::is-active", &onActiveChanged, popup);
    connect(window, "destroy", &onDestroy, popup);
    connect(copy_button, "clicked", &onCopyClicked, popup);
    if (language.list) |list| connect(list, "map", &onLanguageListMapped, popup);

    c.gtk_window_present(window);
    // Start without a focused widget, like before the dropdown existed: keys
    // typed into the fresh popup must not open the list.
    c.gtk_window_set_focus(window, null);
    // Needs the realized window, which `present` gives us.
    connect(c.gtk_widget_get_frame_clock(widget(window)), "after-paint", &onAfterPaint, popup);
    connect(c.gtk_native_get_surface(@ptrCast(window)), "enter-monitor", &onEnterMonitor, popup);

    if (request.problem) |message| {
        // Nothing to translate or copy: only the message and Esc remain.
        c.gtk_widget_set_visible(widget(language.dropdown), 0);
        c.gtk_widget_set_visible(widget(copy_button), 0);
        showError(popup, try gpa.dupeSentinel(u8, message, 0));
    } else {
        if (first_job) |job| watch(job) else translateTo(popup, request.options.forced_target);
        connect(language.dropdown, "notify::selected", &onLanguageSelected, popup);
    }

    c.g_main_loop_run(popup.loop);
    // Workers may still be blocked on the network; exit right away instead
    // of tearing down the allocator and Io they are using.
    std.process.exit(0);
}

/// The original text as one paragraph. `gtk_label_set_lines` limits the lines
/// of each paragraph (Pango), so with line breaks the preview grew unbounded.
fn previewText(gpa: Allocator, text: []const u8) Allocator.Error![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n\x0b\x0c");
    while (words.next()) |word| {
        if (out.items.len > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, word);
    }
    return out.toOwnedSliceSentinel(gpa, 0);
}

/// The notice line for config problems: the first one, and how many more.
fn noticeText(gpa: Allocator, problems: []const []const u8) Allocator.Error![:0]const u8 {
    if (problems.len == 1) return gpa.printSentinel("Config: {s}", .{problems[0]}, 0);
    return gpa.printSentinel("Config: {s} (+{d} more)", .{ problems[0], problems.len - 1 }, 0);
}

fn newWrappingLabel(text: [*:0]const u8, css_class: [*:0]const u8) *c.GtkLabel {
    const label: *c.GtkLabel = @ptrCast(c.gtk_label_new(text));
    c.gtk_label_set_xalign(label, 0);
    c.gtk_label_set_wrap(label, 1);
    c.gtk_label_set_wrap_mode(label, c.PANGO_WRAP_WORD_CHAR);
    // A small natural width makes the label wrap at the card width instead of
    // asking for a window as wide as its text.
    c.gtk_label_set_max_width_chars(label, 1);
    c.gtk_widget_add_css_class(widget(label), css_class);
    return label;
}

/// Entry 0 is "Auto" (the smart rule), then one entry per code in `languages`.
fn newLanguagePicker(
    gpa: Allocator,
    languages: []const []const u8,
    forced_target: ?[]const u8,
) Allocator.Error!struct { dropdown: *c.GtkDropDown, list: ?*c.GtkPopover } {
    const names = c.gtk_string_list_new(null);
    c.gtk_string_list_append(names, "Auto");
    for (languages) |code| c.gtk_string_list_append(names, try languageName(gpa, code));
    const dropdown: *c.GtkDropDown = @ptrCast(c.gtk_drop_down_new(@ptrCast(names), null));
    c.gtk_widget_set_tooltip_text(widget(dropdown), "Target language");
    c.gtk_drop_down_set_selected(dropdown, languageIndex(languages, forced_target));

    var list: ?*c.GtkPopover = null;
    var child: ?*c.GtkWidget = c.gtk_widget_get_first_child(widget(dropdown));
    while (child) |w| : (child = c.gtk_widget_get_next_sibling(w)) {
        if (isA(w, c.gtk_popover_get_type())) {
            list = @ptrCast(w);
            // No grab: with one, KWin moves keyboard focus to the list and,
            // when it closes, on to another window, closing the popup. Without
            // it the list does not close on outside clicks; `onPress` does.
            c.gtk_popover_set_autohide(list, 0);
        } else if (isA(w, c.gtk_button_get_type())) {
            // Flat like the Copy button; the theme styles the inner button.
            c.gtk_widget_add_css_class(w, "flat");
        }
    }
    return .{ .dropdown = dropdown, .list = list };
}

/// The picker entry for a `-t` language, or "Auto" when it is not in the list.
fn languageIndex(languages: []const []const u8, code: ?[]const u8) c.guint {
    const wanted = code orelse return 0;
    for (languages, 1..) |known, i| {
        if (std.ascii.eqlIgnoreCase(known, wanted)) return @intCast(i);
    }
    return 0;
}

/// The display name for a language code; an unknown code is shown uppercased.
fn languageName(gpa: Allocator, code: []const u8) Allocator.Error![:0]const u8 {
    for (language_names) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.code, code)) return entry.name;
    }
    const name = try gpa.allocSentinel(u8, code.len, 0);
    _ = std.ascii.upperString(name, code);
    return name;
}

/// Starts translating the original text into `target` (`null`: smart rule).
fn translateTo(popup: *Popup, target: ?[]const u8) void {
    popup.translated = null;
    c.gtk_widget_remove_css_class(widget(popup.translation), "error");
    c.gtk_label_set_text(popup.translation, "Translating…");
    c.gtk_button_set_label(popup.copy_button, "Copy");
    c.gtk_widget_set_sensitive(widget(popup.copy_button), 0);

    const job = startJob(popup, target) catch |err| {
        return showError(popup, translator.describeError(popup.gpa, err) catch "Translation failed.");
    };
    watch(job);
}

/// Starts a worker that translates into `target`; its result is dropped
/// unless it is still the latest request. Touches no widgets, so it also
/// works before GTK is initialized. The result is shown only after `watch`.
fn startJob(popup: *Popup, target: ?[]const u8) !*Job {
    popup.generation +%= 1;
    const job = try popup.gpa.create(Job);
    job.* = .{ .popup = popup, .generation = popup.generation, .target = target };
    const thread = try std.Thread.spawn(.{}, work, .{job});
    thread.detach();
    return job;
}

/// Lets `job`'s result reach the widgets, which must exist by now, and
/// starts its timeout.
fn watch(job: *Job) void {
    _ = c.g_timeout_add_seconds(translator.request_timeout, onTimeout, job);
    stepDone(job);
}

fn work(job: *Job) void {
    job.outcome = translate(job) catch |err| .{
        .failed = translator.describeError(job.popup.gpa, err) catch "Translation failed.",
    };
    stepDone(job);
}

/// Called by the worker and by `watch`, on different threads; the second
/// call schedules `onResult` on the main loop.
fn stepDone(job: *Job) void {
    // acq_rel: whoever comes second sees the worker's `outcome`.
    if (job.steps_left.fetchSub(1, .acq_rel) == 1) _ = c.g_idle_add(onResult, job);
}

fn translate(job: *Job) !Outcome {
    const popup = job.popup;
    const gpa = popup.gpa;
    var options = popup.request.options;
    options.forced_target = job.target;
    const result = try translator.translateSmart(popup.request.backend, gpa, popup.io, popup.request.text, options);
    const source = try std.ascii.allocUpperString(gpa, result.source_lang);
    const target = try std.ascii.allocUpperString(gpa, result.target_lang);
    return .{ .translated = .{
        .direction = try gpa.printSentinel("{s} → {s}{s}", .{ source, target, serviceLabel(result) }, 0),
        .text = try gpa.dupeSentinel(u8, result.text, 0),
    } };
}

/// The part of the header that names the service.
fn serviceLabel(result: translator.Translation) []const u8 {
    if (result.fell_back) |reason| return switch (reason) {
        .deepl_failed => " · Google (DeepL failed)",
        .too_long => " · Google (too long for DeepL)",
    };
    return switch (result.service) {
        .google => "",
        .deepl => " · DeepL",
        .deepl_web => " · DeepL web",
    };
}

fn onResult(data: c.gpointer) callconv(.c) c.gboolean {
    const job: *Job = @ptrCast(@alignCast(data));
    const popup = job.popup;
    job.done = true;
    // Superseded by a later language choice, or timed out.
    if (job.generation != popup.generation) return c.G_SOURCE_REMOVE;
    switch (job.outcome) {
        .translated => |t| {
            c.gtk_label_set_text(popup.direction, t.direction);
            c.gtk_label_set_text(popup.translation, t.text);
            // Only selectable now: GTK selects all text of a selectable label
            // that receives the initial focus.
            c.gtk_label_set_selectable(popup.translation, 1);
            c.gtk_widget_set_sensitive(widget(popup.copy_button), 1);
            popup.translated = t.text;
        },
        .failed => |message| showError(popup, message),
    }
    // A mapped GTK4 window only changes to its new natural size when asked to.
    c.gtk_window_set_default_size(popup.window, -1, -1);
    return c.G_SOURCE_REMOVE;
}

/// Gives up on a request that is still running. Its worker stays blocked
/// until the network answers or the process exits; the result is dropped.
fn onTimeout(data: c.gpointer) callconv(.c) c.gboolean {
    const job: *Job = @ptrCast(@alignCast(data));
    const popup = job.popup;
    if (!job.done and job.generation == popup.generation) {
        popup.generation +%= 1;
        showError(popup, translator.describeError(popup.gpa, error.TimedOut) catch "Translation failed.");
        c.gtk_window_set_default_size(popup.window, -1, -1);
    }
    return c.G_SOURCE_REMOVE;
}

fn showError(popup: *Popup, message: [*:0]const u8) void {
    // The direction of an earlier translation no longer applies.
    c.gtk_label_set_text(popup.direction, "Translate");
    c.gtk_label_set_text(popup.translation, message);
    c.gtk_widget_add_css_class(widget(popup.translation), "error");
}

fn onLanguageSelected(_: *c.GObject, _: *c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(data));
    const index = c.gtk_drop_down_get_selected(popup.language);
    const languages = popup.request.languages;
    if (index == 0) {
        translateTo(popup, null);
    } else if (index <= languages.len) {
        translateTo(popup, languages[index - 1]);
    }
}

fn onLanguageListMapped(list: *c.GtkWidget, _: c.gpointer) callconv(.c) void {
    // Without a grab the list does not take focus itself; arrow keys need it.
    _ = c.gtk_widget_child_focus(list, c.GTK_DIR_TAB_FORWARD);
}

fn languageListOpen(popup: *Popup) bool {
    const list = popup.language_list orelse return false;
    return c.gtk_widget_get_visible(widget(list)) != 0;
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    modifiers: c.GdkModifierType,
    data: c.gpointer,
) callconv(.c) c.gboolean {
    const popup: *Popup = @ptrCast(@alignCast(data));
    if (keyval == c.GDK_KEY_Escape) {
        if (languageListOpen(popup)) {
            c.gtk_popover_popdown(popup.language_list);
        } else {
            c.gtk_window_close(popup.window);
        }
        return 1;
    }
    if (modifiers & c.GDK_CONTROL_MASK != 0 and (keyval == c.GDK_KEY_c or keyval == c.GDK_KEY_C)) {
        copy(popup);
        return 1;
    }
    return 0;
}

fn onCopyClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    copy(@ptrCast(@alignCast(data)));
}

fn onActiveChanged(_: *c.GObject, _: *c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(data));
    if (c.gtk_window_is_active(popup.window) != 0) {
        popup.was_active = true;
    } else {
        // Focus can bounce while the language list opens or closes; only a
        // lasting loss closes the popup.
        _ = c.g_timeout_add(focus_settle_time, onFocusSettled, popup);
    }
}

fn onFocusSettled(data: c.gpointer) callconv(.c) c.gboolean {
    const popup: *Popup = @ptrCast(@alignCast(data));
    if (popup.was_active and c.gtk_window_is_active(popup.window) == 0) c.gtk_window_close(popup.window);
    return c.G_SOURCE_REMOVE;
}

fn onDestroy(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(data));
    c.g_main_loop_quit(popup.loop);
}

// Dragging. A layer surface cannot be moved by the compositor, so a drag
// pins the popup by its top-left corner and changes the layer-shell margins.
// Pointer coordinates are relative to the surface, which moves only once the
// compositor applies a commit; `drag_base` therefore advances per committed
// frame (`onAfterPaint`), not per event.

/// Sees every press on the popup first (capture phase): closes the language
/// list when the press is elsewhere, and starts a drag on a drag handle.
fn onPress(gesture: *c.GtkGestureDrag, x: f64, y: f64, data: c.gpointer) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(data));
    popup.dragging = false;
    // Presses inside the language list propagate through the window too.
    const event = c.gtk_event_controller_get_current_event(@ptrCast(gesture));
    const on_window = c.gdk_event_get_surface(event) == c.gtk_native_get_surface(@ptrCast(popup.window));
    const picked: ?*c.GtkWidget = if (on_window) c.gtk_widget_pick(widget(popup.window), x, y, c.GTK_PICK_DEFAULT) else null;
    if (picked) |w| {
        const on_picker = w == widget(popup.language) or c.gtk_widget_is_ancestor(w, widget(popup.language)) != 0;
        if (!on_picker and languageListOpen(popup)) c.gtk_popover_popdown(popup.language_list);
    }
    const on_handle = if (picked) |w| std.mem.findScalar(*c.GtkWidget, &popup.drag_handles, w) != null else false;
    if (!on_handle or c.gtk_layer_is_layer_window(popup.window) == 0) {
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_DENIED);
    }
}

fn onDragUpdate(gesture: *c.GtkGestureDrag, dx: f64, dy: f64, data: c.gpointer) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(data));
    if (!popup.dragging) {
        if (@abs(dx) < drag_threshold and @abs(dy) < drag_threshold) return;
        _ = c.gtk_gesture_set_state(@ptrCast(gesture), c.GTK_EVENT_SEQUENCE_CLAIMED);
        beginMove(popup);
    }
    moveBy(popup, @intFromFloat(@round(dx)), @intFromFloat(@round(dy)));
}

fn onDragEnd(_: *c.GtkGestureDrag, _: f64, _: f64, data: c.gpointer) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(data));
    // A press that never passed `drag_threshold` did not move anything.
    if (!popup.dragging) return;
    popup.dragging = false;
    if (popup.request.position_path) |path| state.savePosition(popup.io, path, margins(popup.window));
}

/// Runs after every frame. While dragging it advances `drag_base`; otherwise
/// it notices a new window size (the resize after `set_default_size(-1, -1)`
/// lands in some later frame) and pulls an overflowing popup back on screen.
fn onAfterPaint(_: *c.GdkFrameClock, data: c.gpointer) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(data));
    if (popup.dragging) {
        popup.drag_base = margins(popup.window);
        return;
    }
    const size = windowSize(popup.window);
    if (std.mem.eql(c_int, &size, &popup.checked_size)) return;
    // No monitor yet: try again next frame, or on `enter-monitor`.
    const area = monitorArea(popup.window) orelse return;
    popup.checked_size = size;
    keepOnScreen(popup, area);
}

/// The monitor is known only once the compositor has shown the surface on it.
fn onEnterMonitor(_: *c.GdkSurface, monitor: *c.GdkMonitor, data: c.gpointer) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(data));
    if (popup.dragging) return;
    var area: c.GdkRectangle = undefined;
    c.gdk_monitor_get_geometry(monitor, &area);
    popup.checked_size = windowSize(popup.window);
    keepOnScreen(popup, area);
}

/// Caps the translation's height so the popup fits on the monitor below the
/// default top margin, then moves the popup up or left just enough to be
/// fully inside `area`.
fn keepOnScreen(popup: *Popup, area: c.GdkRectangle) void {
    const window = popup.window;
    if (c.gtk_layer_is_layer_window(window) == 0) return;
    var size = windowSize(window);
    const shown = c.gtk_widget_get_height(widget(popup.scroller));
    const cap = translationCap(area.height, size[1] - shown);
    if (cap != c.gtk_scrolled_window_get_max_content_height(popup.scroller)) {
        c.gtk_scrolled_window_set_max_content_height(popup.scroller, cap);
        c.gtk_window_set_default_size(window, -1, -1);
    }
    // Place it for the height it is about to shrink to, if any.
    size[1] -= @max(0, shown - cap);
    const current = margins(window);
    const wanted = clampPosition(current, size, .{ area.width, area.height });
    if (std.mem.eql(c_int, &current, &wanted)) return;
    // Centered (not left-anchored) popups ignore the left margin; it stays 0.
    c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_LEFT, wanted[0]);
    c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_TOP, wanted[1]);
    c.gtk_widget_queue_draw(widget(window));
}

/// Switches from horizontal centering to left anchoring without moving.
fn beginMove(popup: *Popup) void {
    const window = popup.window;
    if (c.gtk_layer_get_anchor(window, c.GTK_LAYER_SHELL_EDGE_LEFT) == 0) {
        if (monitorArea(window)) |area| {
            const left = @divTrunc(area.width - c.gtk_widget_get_width(widget(window)), 2);
            c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_LEFT, 1);
            c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_LEFT, left);
        }
    }
    popup.drag_base = margins(window);
    popup.dragging = true;
}

/// Moves the popup by the pointer offset from `drag_base`, keeping it on the monitor.
fn moveBy(popup: *Popup, dx: c_int, dy: c_int) void {
    const window = popup.window;
    if (c.gtk_layer_get_anchor(window, c.GTK_LAYER_SHELL_EDGE_LEFT) == 0) return;
    const area = monitorArea(window) orelse return;
    const position = clampPosition(
        .{ popup.drag_base[0] + dx, popup.drag_base[1] + dy },
        windowSize(window),
        .{ area.width, area.height },
    );
    c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_LEFT, position[0]);
    c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_TOP, position[1]);
    // Make sure this frame paints (and commits), so `onAfterPaint` runs.
    c.gtk_widget_queue_draw(widget(window));
}

fn margins(window: *c.GtkWindow) [2]c_int {
    return .{
        c.gtk_layer_get_margin(window, c.GTK_LAYER_SHELL_EDGE_LEFT),
        c.gtk_layer_get_margin(window, c.GTK_LAYER_SHELL_EDGE_TOP),
    };
}

/// The most the translation may take on a monitor `area_height` tall when the
/// rest of the popup takes `others`: the popup ends at the monitor's bottom
/// when it starts at the default top margin.
fn translationCap(area_height: c_int, others: c_int) c_int {
    return std.math.clamp(area_height - top_margin - others, min_translation_height, max_translation_height);
}

/// Clamps a top-left `position` so a window of `size` lies fully inside a
/// monitor of `area` (both width, height). Too big a window sits at 0.
fn clampPosition(position: [2]c_int, size: [2]c_int, area: [2]c_int) [2]c_int {
    var result: [2]c_int = undefined;
    for (&result, position, size, area) |*r, p, s, a| r.* = std.math.clamp(p, 0, @max(0, a - s));
    return result;
}

fn windowSize(window: *c.GtkWindow) [2]c_int {
    return .{ c.gtk_widget_get_width(widget(window)), c.gtk_widget_get_height(widget(window)) };
}

fn monitorArea(window: *c.GtkWindow) ?c.GdkRectangle {
    const surface = c.gtk_native_get_surface(@ptrCast(window)) orelse return null;
    const monitor = c.gdk_display_get_monitor_at_surface(c.gtk_widget_get_display(widget(window)), surface) orelse return null;
    var area: c.GdkRectangle = undefined;
    c.gdk_monitor_get_geometry(monitor, &area);
    return area;
}

/// Copies the selected part of the translation, or all of it when nothing is
/// selected. Uses wl-copy so the clipboard survives this process exiting.
fn copy(popup: *Popup) void {
    const text = popup.translated orelse return;
    var start: c_int = 0;
    var end: c_int = 0;
    const selected = if (c.gtk_label_get_selection_bounds(popup.translation, &start, &end) != 0)
        text[byteOffset(text, @intCast(start))..byteOffset(text, @intCast(end))]
    else
        text;

    const term = runWlCopy(popup.io, "wl-copy", selected) catch |err| {
        std.debug.print("wl-copy failed: {t}\n", .{err});
        c.gtk_button_set_label(popup.copy_button, "Copy failed");
        return;
    };
    c.gtk_button_set_label(popup.copy_button, if (term.success()) "Copied" else "Copy failed");
}

/// Runs wl-copy (`program`) with `text` on its standard input. Not as an
/// argument: other users could see that in the process list, and a long text
/// would hit the argument size limit.
fn runWlCopy(io: Io, program: []const u8, text: []const u8) !std.process.Child.Term {
    // wl-copy forks a background process that serves the clipboard until it
    // is replaced. It inherits no stdout/stderr, so it cannot keep a caller's
    // pipe open, and stdin is closed before waiting.
    var child = try std.process.spawn(io, .{
        // An explicit type: from stdin, wl-copy would otherwise guess one with
        // xdg-mime, and text that looks like HTML could be offered as HTML.
        .argv = &.{ program, "--type", "text/plain;charset=utf-8" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io); // Reaps the child when writing failed; no-op after `wait`.
    const stdin = child.stdin.?;
    child.stdin = null;
    const written = stdin.writeStreamingAll(io, text);
    stdin.close(io);
    try written;
    return child.wait(io);
}

fn byteOffset(text: []const u8, char_offset: usize) usize {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var chars: usize = 0;
    while (chars < char_offset and it.nextCodepointSlice() != null) chars += 1;
    return it.i;
}

fn isA(w: *c.GtkWidget, gtype: c.GType) bool {
    return c.g_type_check_instance_is_a(@ptrCast(w), gtype) != 0;
}

fn widget(ptr: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(ptr));
}

fn connect(instance: anytype, signal: [*:0]const u8, handler: anytype, popup: *Popup) void {
    _ = c.g_signal_connect_data(instance, signal, @ptrCast(handler), popup, null, 0);
}

test languageIndex {
    const languages: []const []const u8 = &.{ "tr", "en", "de", "zh-CN" };
    try std.testing.expectEqual(0, languageIndex(languages, null));
    try std.testing.expectEqual(3, languageIndex(languages, "de"));
    try std.testing.expectEqual(4, languageIndex(languages, "zh-cn"));
    try std.testing.expectEqual(0, languageIndex(languages, "xx"));
}

test languageName {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqualStrings("Deutsch", try languageName(gpa, "de"));
    try std.testing.expectEqualStrings("繁體中文", try languageName(gpa, "ZH-tw"));
    try std.testing.expectEqualStrings("XX-YY", try languageName(gpa, "xx-yy"));
}

test clampPosition {
    const size: [2]c_int = .{ 584, 200 };
    const area: [2]c_int = .{ 1920, 1080 };
    // Inside: unchanged.
    try std.testing.expectEqual([2]c_int{ 100, 80 }, clampPosition(.{ 100, 80 }, size, area));
    // Exactly at the far edges: unchanged.
    try std.testing.expectEqual([2]c_int{ 1336, 880 }, clampPosition(.{ 1336, 880 }, size, area));
    // Past the right and bottom edges (or a smaller monitor): pulled back.
    try std.testing.expectEqual([2]c_int{ 1336, 880 }, clampPosition(.{ 3000, 2000 }, size, area));
    // A popup that grew past the bottom moves up just enough.
    try std.testing.expectEqual([2]c_int{ 100, 780 }, clampPosition(.{ 100, 780 }, .{ 584, 300 }, area));
    try std.testing.expectEqual([2]c_int{ 100, 780 }, clampPosition(.{ 100, 850 }, .{ 584, 300 }, area));
    // Negative: to the edge.
    try std.testing.expectEqual([2]c_int{ 0, 0 }, clampPosition(.{ -40, -1 }, size, area));
    // Bigger than the monitor: top-left corner.
    try std.testing.expectEqual([2]c_int{ 0, 0 }, clampPosition(.{ 50, 50 }, .{ 2000, 1200 }, area));
}

test translationCap {
    // A normal monitor: the fixed maximum.
    try std.testing.expectEqual(max_translation_height, translationCap(1080, 156));
    // A small one: what is left below the top margin.
    try std.testing.expectEqual(500 - top_margin - 156, translationCap(500, 156));
    // Tiny: never below the minimum.
    try std.testing.expectEqual(min_translation_height, translationCap(200, 156));
}

test runWlCopy {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Fake wl-copy scripts that record stdin and argv next to themselves. The
    // real one is never run: it would replace the user's clipboard.
    const record = "#!/bin/sh\nexec 3<&0\ncat > \"$0.stdin\"\nprintf '%s\\n' \"$@\" > \"$0.args\"\n";
    const scripts = [_][2][]const u8{
        .{ "ok", record },
        .{ "fails", record ++ "exit 3\n" },
        // Forks like wl-copy: the background process keeps stdin, stdout and
        // stderr open (sh would give it /dev/null as stdin, hence fd 3).
        .{ "forks", record ++ "sleep 5 <&3 &\n" },
    };
    for (scripts) |script| try tmp.dir.writeFile(io, .{
        .sub_path = script[0],
        .data = script[1],
        .flags = .{ .permissions = .executable_file },
    });

    const big = try gpa.alloc(u8, 300 * 1024);
    defer gpa.free(big);
    const pattern = "Merhaba dünya, 日本語 -- \n";
    for (big, 0..) |*b, i| b.* = pattern[i % pattern.len];
    const texts = [_][]const u8{ "Hello", "Güzel gün → 日本語", "--help -t x", "\n", "", big };

    const ok = try tmp.dir.realPathFileAlloc(io, "ok", gpa);
    defer gpa.free(ok);
    for (texts) |text| {
        try std.testing.expect((try runWlCopy(io, ok, text)).success());
        const stdin = try tmp.dir.readFileAlloc(io, "ok.stdin", gpa, .unlimited);
        defer gpa.free(stdin);
        try std.testing.expectEqualSlices(u8, text, stdin);
        const args = try tmp.dir.readFileAlloc(io, "ok.args", gpa, .unlimited);
        defer gpa.free(args);
        try std.testing.expectEqualStrings("--type\ntext/plain;charset=utf-8\n", args);
    }

    const fails = try tmp.dir.realPathFileAlloc(io, "fails", gpa);
    defer gpa.free(fails);
    try std.testing.expect(!(try runWlCopy(io, fails, "Hello")).success());

    const forks = try tmp.dir.realPathFileAlloc(io, "forks", gpa);
    defer gpa.free(forks);
    const start: Io.Clock.Timestamp = .now(io, .awake);
    try std.testing.expect((try runWlCopy(io, forks, big)).success());
    try std.testing.expect(start.untilNow(io).raw.toMilliseconds() < 2000);
}

test previewText {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqualStrings("one two three", try previewText(gpa, "one\ntwo\r\n\n  three\n"));
    try std.testing.expectEqualStrings("a b", try previewText(gpa, "\ta\x0cb "));
    try std.testing.expectEqualStrings("Merhaba dünya", try previewText(gpa, "Merhaba dünya"));
    try std.testing.expectEqualStrings("", try previewText(gpa, " \n "));
}

test noticeText {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqualStrings(
        "Config: line 3: unknown key \"colour\"",
        try noticeText(gpa, &.{"line 3: unknown key \"colour\""}),
    );
    try std.testing.expectEqualStrings(
        "Config: line 1: expected `key = value` (+2 more)",
        try noticeText(gpa, &.{ "line 1: expected `key = value`", "line 2: unknown backend \"bing\"", "backend = deepl needs deepl_key; using Google" }),
    );
}
