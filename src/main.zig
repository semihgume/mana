const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const selection = @import("selection.zig");
const state = @import("state.zig");
const translator = @import("translator.zig");
const ui = @import("ui.zig");

const usage =
    \\Usage: mana [--print] [-t LANG] [TEXT...]
    \\
    \\Translates TEXT, or the current selection when no TEXT is given, and
    \\shows the result in a popup.
    \\
    \\  --print   Print the translation to stdout instead of showing a popup.
    \\  -t LANG   Always translate into LANG.
    \\
    \\Settings are read from ~/.config/mana/config.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const settings = try config.load(arena, io, init.environ_map);

    const args = try init.minimal.args.toSlice(arena);
    var print_mode = false;
    var options: translator.Options = .{ .primary_lang = settings.native, .secondary_lang = settings.fallback };
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--print")) {
            print_mode = true;
        } else if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
            i += 1;
            options.forced_target = args[i];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else {
            try words.append(arena, arg);
        }
    }

    var problem: ?[]const u8 = null;
    const text = if (words.items.len > 0)
        try std.mem.join(arena, " ", words.items)
    else
        selection.read(arena, io) catch |err| blk: {
            problem = switch (err) {
                error.FileNotFound => "wl-paste was not found. Install wl-clipboard to translate the selection.",
                error.Timeout => "Could not read the selection: the application that owns it did not answer.",
                error.NotText => "The selection is not text.",
                else => try arena.print("Could not read the selection ({t}).", .{err}),
            };
            break :blk "";
        };
    if (problem == null and text.len == 0) problem = "No text selected.";

    const backend: translator.Backend = switch (settings.backend) {
        .google => .google,
        .deepl => if (settings.deepl_key) |key| .{ .deepl = .{ .key = key } } else blk: {
            std.debug.print("mana: config: backend = deepl needs deepl_key; using Google\n", .{});
            break :blk .google;
        },
        .deepl_web => .deepl_web,
    };

    if (!print_mode) try ui.run(arena, io, .{
        .text = text,
        .problem = problem,
        .backend = backend,
        .options = options,
        .languages = settings.languages,
        .position_path = try state.positionPath(arena, init.environ_map),
    });

    if (problem) |message| {
        std.debug.print("{s}\n", .{message});
        std.process.exit(1);
    }

    const result = translator.translateSmart(backend, arena, io, text, options) catch |err| {
        std.debug.print("{s}\n", .{try translator.describeError(arena, err)});
        std.process.exit(1);
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print("[{s} -> {s}{s}]\n{s}\n", .{ result.source_lang, result.target_lang, serviceLabel(result), result.text });
    try stdout.flush();
}

/// The part of the `--print` header that names the service.
fn serviceLabel(result: translator.Translation) []const u8 {
    if (result.fell_back) |reason| return switch (reason) {
        .deepl_failed => ", Google: DeepL failed",
        .too_long => ", Google: too long for DeepL",
    };
    return switch (result.service) {
        .google => "",
        .deepl => ", DeepL",
        .deepl_web => ", DeepL web",
    };
}

test serviceLabel {
    var result: translator.Translation = .{ .text = "", .source_lang = "en", .target_lang = "tr", .service = .deepl_web };
    try std.testing.expectEqualStrings(", DeepL web", serviceLabel(result));
    result = .{ .text = "", .source_lang = "en", .target_lang = "tr", .service = .google, .fell_back = .too_long };
    try std.testing.expectEqualStrings(", Google: too long for DeepL", serviceLabel(result));
    result.fell_back = .deepl_failed;
    try std.testing.expectEqualStrings(", Google: DeepL failed", serviceLabel(result));
}

test {
    _ = config;
    _ = selection;
    _ = state;
    _ = translator;
    _ = ui;
}
