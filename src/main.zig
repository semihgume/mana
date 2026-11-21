const std = @import("std");
const Io = std.Io;
const selection = @import("selection.zig");
const translator = @import("translator.zig");
const ui = @import("ui.zig");

const primary_lang = "tr";
const secondary_lang = "en";

const usage =
    \\Usage: mana [--print] [-t LANG] [TEXT...]
    \\
    \\Translates TEXT, or the current selection when no TEXT is given, and
    \\shows the result in a popup.
    \\
    \\  --print   Print the translation to stdout instead of showing a popup.
    \\  -t LANG   Always translate into LANG.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    var print_mode = false;
    var options: translator.Options = .{ .primary_lang = primary_lang, .secondary_lang = secondary_lang };
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
            problem = try arena.print("Could not read the selection: {t}", .{err});
            break :blk "";
        };
    if (problem == null and text.len == 0) problem = "No text selected.";

    const backend: translator.Backend = .google;

    if (!print_mode) try ui.run(arena, io, .{
        .text = text,
        .problem = problem,
        .backend = backend,
        .options = options,
    });

    if (problem) |message| {
        std.debug.print("{s}\n", .{message});
        std.process.exit(1);
    }

    const result = try translator.translateSmart(backend, arena, io, text, options);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print("[{s} -> {s}]\n{s}\n", .{ result.source_lang, result.target_lang, result.text });
    try stdout.flush();
}

test {
    _ = translator;
    _ = ui;
}
