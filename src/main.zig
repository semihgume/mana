const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const selection = @import("selection.zig");
const state = @import("state.zig");
const translator = @import("translator.zig");
const ui = @import("ui.zig");
const build_options = @import("build_options");

const usage =
    \\Usage: mana [--print] [-t LANG] [TEXT...]
    \\
    \\Translates TEXT, or the current selection when no TEXT is given, and
    \\shows the result in a popup.
    \\
    \\  --print         Print the translation to stdout instead of showing a popup.
    \\  -t LANG         Always translate into LANG.
    \\  -V, --version   Print the version and exit.
    \\
    \\Settings are read from ~/.config/mana/config.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    var print_mode = false;
    var forced_target: ?[]const u8 = null;
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--print")) {
            print_mode = true;
        } else if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
            i += 1;
            forced_target = args[i];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            try printStdout(io, "mana {s}\n", .{build_options.version});
            return;
        } else {
            try words.append(arena, arg);
        }
    }

    var config_problems: std.ArrayList([]const u8) = .empty;
    const settings = try config.load(arena, io, init.environ_map, &config_problems);
    const options: translator.Options = .{
        .primary_lang = settings.native,
        .secondary_lang = settings.fallback,
        .forced_target = forced_target,
    };

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
            const message = "backend = deepl needs deepl_key; using Google";
            std.debug.print("mana: config: {s}\n", .{message});
            try config_problems.append(arena, message);
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
        .config_problems = config_problems.items,
    });

    if (problem) |message| {
        std.debug.print("{s}\n", .{message});
        std.process.exit(1);
    }

    // The http client has no timeout and cancelling a request is unreliable,
    // so translate on a worker and stop waiting for it after the timeout.
    var job: PrintJob = .{ .backend = backend, .arena = arena, .io = io, .text = text, .options = options };
    const worker = try std.Thread.spawn(.{}, PrintJob.work, .{&job});
    const timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(translator.request_timeout), .clock = .awake };
    job.done.waitTimeout(io, .{ .deadline = .fromNow(io, timeout) }) catch |err| switch (err) {
        error.Timeout => {
            std.debug.print("{s}\n", .{try translator.describeError(arena, error.TimedOut)});
            // The worker still uses `io` and `arena`: exit instead of returning.
            std.process.exit(1);
        },
        error.Canceled => |e| return e,
    };
    worker.join();

    const result = job.result catch |err| {
        std.debug.print("{s}\n", .{try translator.describeError(arena, err)});
        std.process.exit(1);
    };
    try printStdout(io, "[{s} -> {s}{s}]\n{s}\n", .{ result.source_lang, result.target_lang, serviceLabel(result), result.text });
}

/// The `--print` translation, run on a worker thread so `main` can give up on it.
const PrintJob = struct {
    backend: translator.Backend,
    arena: std.mem.Allocator,
    io: Io,
    text: []const u8,
    options: translator.Options,
    result: anyerror!translator.Translation = undefined,
    done: Io.Event = .unset,

    fn work(job: *PrintJob) void {
        job.result = translator.translateSmart(job.backend, job.arena, job.io, job.text, job.options);
        job.done.set(job.io);
    }
};

fn printStdout(io: Io, comptime format: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    try file_writer.interface.print(format, args);
    try file_writer.interface.flush();
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
