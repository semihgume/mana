const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("c");
const translator = @import("translator.zig");

pub const Request = struct {
    text: []const u8,
    /// Shown instead of a translation, e.g. when nothing was selected.
    problem: ?[]const u8,
    backend: translator.Backend,
    options: translator.Options,
    /// Target language codes offered in the picker after "Auto", in order.
    languages: []const []const u8,
};

const popup_width = 560;
const max_translation_height = 360;
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
    \\.error { color: @error_color; }
;

const Popup = struct {
    gpa: Allocator,
    io: Io,
    request: Request,
    loop: *c.GMainLoop,
    window: *c.GtkWindow,
    direction: *c.GtkLabel,
    translation: *c.GtkLabel,
    copy_button: *c.GtkButton,
    language: *c.GtkDropDown,
    /// The dropdown's list. GtkDropDown has no getter; it is a child widget.
    language_list: ?*c.GtkPopover,
    /// Widgets a drag may start on: the header row and the card's empty
    /// space, but not the text labels, so text selection keeps working.
    drag_handles: [4]*c.GtkWidget,
    /// Bumped for every translation request; older results are dropped.
    generation: u32 = 0,
    translated: ?[:0]const u8 = null,
    was_active: bool = false,
    dragging: bool = false,
    /// Layer-shell margins (left, top) the incoming pointer events are
    /// relative to: the ones of the last committed frame.
    drag_base: [2]c_int = .{ 0, 0 },
};

/// One translation request. Never freed (the process is short-lived), so a
/// worker that finishes after a newer request started writes to valid memory.
const Job = struct {
    popup: *Popup,
    generation: u32,
    /// `null` applies the smart rule.
    target: ?[]const u8,
    /// Written by the worker thread before it schedules `onResult`.
    outcome: Outcome = undefined,
};

const Outcome = union(enum) {
    translated: struct { direction: [:0]const u8, text: [:0]const u8 },
    failed: [:0]const u8,
};

/// Shows the popup and runs the GTK main loop. Exits the process when the
/// popup closes; returns only if the UI cannot be started.
pub fn run(gpa: Allocator, io: Io, request: Request) !noreturn {
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

    const original = newWrappingLabel(try gpa.dupeSentinel(u8, request.text, 0), "original");
    c.gtk_label_set_lines(original, 3);
    c.gtk_label_set_ellipsize(original, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_append(@ptrCast(card), widget(original));

    const translation = newWrappingLabel("Translating…", "translation");
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_max_content_height(@ptrCast(scroller), max_translation_height);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), widget(translation));
    c.gtk_box_append(@ptrCast(card), scroller);

    const popup = try gpa.create(Popup);
    popup.* = .{
        .gpa = gpa,
        .io = io,
        .request = request,
        .loop = c.g_main_loop_new(null, 0).?,
        .window = window,
        .direction = direction,
        .translation = translation,
        .copy_button = copy_button,
        .language = language.dropdown,
        .language_list = language.list,
        .drag_handles = .{ widget(window), card, header, widget(direction) },
    };

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

    if (request.problem) |message| {
        c.gtk_widget_set_sensitive(widget(language.dropdown), 0);
        showError(popup, try gpa.dupeSentinel(u8, message, 0));
    } else {
        translateTo(popup, request.options.forced_target);
        connect(language.dropdown, "notify::selected", &onLanguageSelected, popup);
    }

    c.g_main_loop_run(popup.loop);
    // Workers may still be blocked on the network; exit right away instead
    // of tearing down the allocator and Io they are using.
    std.process.exit(0);
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
    popup.generation +%= 1;
    popup.translated = null;
    c.gtk_widget_remove_css_class(widget(popup.translation), "error");
    c.gtk_label_set_text(popup.translation, "Translating…");
    c.gtk_button_set_label(popup.copy_button, "Copy");
    c.gtk_widget_set_sensitive(widget(popup.copy_button), 0);

    const job = popup.gpa.create(Job) catch return showError(popup, "Translation failed: OutOfMemory");
    job.* = .{ .popup = popup, .generation = popup.generation, .target = target };
    const thread = std.Thread.spawn(.{}, work, .{job}) catch |err| {
        return showError(popup, popup.gpa.printSentinel("Translation failed: {t}", .{err}, 0) catch "Translation failed.");
    };
    thread.detach();
}

fn work(job: *Job) void {
    job.outcome = translate(job) catch |err| .{
        .failed = job.popup.gpa.printSentinel("Translation failed: {t}", .{err}, 0) catch "Translation failed.",
    };
    _ = c.g_idle_add(onResult, job);
}

fn translate(job: *Job) !Outcome {
    const popup = job.popup;
    const gpa = popup.gpa;
    var options = popup.request.options;
    options.forced_target = job.target;
    const result = try translator.translateSmart(popup.request.backend, gpa, popup.io, popup.request.text, options);
    const source = try std.ascii.allocUpperString(gpa, result.source_lang);
    const target = try std.ascii.allocUpperString(gpa, result.target_lang);
    const service: []const u8 = if (result.fell_back)
        " · Google (DeepL failed)"
    else switch (result.service) {
        .google => "",
        .deepl => " · DeepL",
        .deepl_web => " · DeepL web",
    };
    return .{ .translated = .{
        .direction = try gpa.printSentinel("{s} → {s}{s}", .{ source, target, service }, 0),
        .text = try gpa.dupeSentinel(u8, result.text, 0),
    } };
}

fn onResult(data: c.gpointer) callconv(.c) c.gboolean {
    const job: *Job = @ptrCast(@alignCast(data));
    const popup = job.popup;
    // Superseded by a later language choice; that request will report.
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

fn showError(popup: *Popup, message: [*:0]const u8) void {
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
    state: c.GdkModifierType,
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
    if (state & c.GDK_CONTROL_MASK != 0 and (keyval == c.GDK_KEY_c or keyval == c.GDK_KEY_C)) {
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
    popup.dragging = false;
}

fn onAfterPaint(_: *c.GdkFrameClock, data: c.gpointer) callconv(.c) void {
    const popup: *Popup = @ptrCast(@alignCast(data));
    if (popup.dragging) popup.drag_base = margins(popup.window);
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
    const max_left = @max(0, area.width - c.gtk_widget_get_width(widget(window)));
    const max_top = @max(0, area.height - c.gtk_widget_get_height(widget(window)));
    c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_LEFT, std.math.clamp(popup.drag_base[0] + dx, 0, max_left));
    c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_TOP, std.math.clamp(popup.drag_base[1] + dy, 0, max_top));
    // Make sure this frame paints (and commits), so `onAfterPaint` runs.
    c.gtk_widget_queue_draw(widget(window));
}

fn margins(window: *c.GtkWindow) [2]c_int {
    return .{
        c.gtk_layer_get_margin(window, c.GTK_LAYER_SHELL_EDGE_LEFT),
        c.gtk_layer_get_margin(window, c.GTK_LAYER_SHELL_EDGE_TOP),
    };
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

    // wl-copy forks a background process that serves the clipboard until it
    // is replaced; no inherited stdio, so it cannot keep a caller's pipe open.
    var child = std.process.spawn(popup.io, .{
        .argv = &.{ "wl-copy", "--", selected },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.debug.print("Could not run wl-copy: {t}\n", .{err});
        return;
    };
    const term = child.wait(popup.io) catch return;
    const ok = term == .exited and term.exited == 0;
    c.gtk_button_set_label(popup.copy_button, if (ok) "Copied" else "Copy failed");
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
