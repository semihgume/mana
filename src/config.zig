const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const BackendKind = enum { google, deepl, deepl_web };

/// Same codes and order as the language picker in ui.zig.
const default_languages = [_][]const u8{ "tr", "en", "de", "fr", "es", "it", "ru", "ar", "ja", "zh-CN" };

pub const Config = struct {
    backend: BackendKind = .google,
    native: []const u8 = "tr",
    fallback: []const u8 = "en",
    languages: []const []const u8 = &default_languages,
    deepl_key: ?[]const u8 = null,
};

const max_file_size = 64 * 1024;
const whitespace = " \t\r";

/// Pure parser. Never fails on bad content: an unknown key, a line without `=`,
/// or an invalid value is skipped and reported as a warning ("line N: ..."),
/// and the default for that setting stays. Only allocation failure is an error.
pub fn parse(arena: Allocator, text: []const u8, warnings: *std.ArrayList([]const u8)) Allocator.Error!Config {
    var config: Config = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            try warnings.append(arena, try arena.print("line {d}: expected `key = value`", .{line_number}));
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], whitespace);
        const value = std.mem.trim(u8, line[eq + 1 ..], whitespace);

        if (std.mem.eql(u8, key, "backend")) {
            if (std.ascii.eqlIgnoreCase(value, "google")) {
                config.backend = .google;
            } else if (std.ascii.eqlIgnoreCase(value, "deepl")) {
                config.backend = .deepl;
            } else if (std.ascii.eqlIgnoreCase(value, "deepl-web") or std.ascii.eqlIgnoreCase(value, "deepl_web")) {
                config.backend = .deepl_web;
            } else {
                try warnings.append(arena, try arena.print("line {d}: unknown backend \"{s}\"", .{ line_number, value }));
            }
        } else if (std.mem.eql(u8, key, "native") or std.mem.eql(u8, key, "fallback")) {
            if (value.len == 0) {
                try warnings.append(arena, try arena.print("line {d}: {s} is empty", .{ line_number, key }));
                continue;
            }
            const code = try arena.dupe(u8, value);
            if (key[0] == 'n') config.native = code else config.fallback = code;
        } else if (std.mem.eql(u8, key, "languages")) {
            var codes: std.ArrayList([]const u8) = .empty;
            var entries = std.mem.splitScalar(u8, value, ',');
            while (entries.next()) |entry| {
                const code = std.mem.trim(u8, entry, whitespace);
                if (code.len > 0) try codes.append(arena, try arena.dupe(u8, code));
            }
            if (codes.items.len == 0) {
                try warnings.append(arena, try arena.print("line {d}: languages is empty", .{line_number}));
                continue;
            }
            config.languages = codes.items;
        } else if (std.mem.eql(u8, key, "deepl_key")) {
            config.deepl_key = if (value.len == 0) null else try arena.dupe(u8, value);
        } else {
            try warnings.append(arena, try arena.print("line {d}: unknown key \"{s}\"", .{ line_number, key }));
        }
    }
    return config;
}

/// Reads and parses the config file. A missing file silently yields defaults.
/// Any other read problem and every parse warning is printed to stderr with
/// std.debug.print prefixed "mana: config: ", and defaults/partial config are
/// returned. The same problems are appended to `problems` as short messages
/// without the file's path, for the popup. Never returns an error to the
/// caller except OutOfMemory.
pub fn load(
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    problems: *std.ArrayList([]const u8),
) Allocator.Error!Config {
    const xdg = environ.get("XDG_CONFIG_HOME") orelse "";
    const config_path = if (xdg.len > 0)
        try std.fs.path.join(arena, &.{ xdg, "mana", "config" })
    else if (environ.get("HOME")) |home|
        try std.fs.path.join(arena, &.{ home, ".config", "mana", "config" })
    else {
        std.debug.print("mana: config: neither XDG_CONFIG_HOME nor HOME is set\n", .{});
        try problems.append(arena, "neither XDG_CONFIG_HOME nor HOME is set");
        return .{};
    };

    const text = Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.debug.print("mana: config: cannot read {s}: {t}\n", .{ config_path, err });
            try problems.append(arena, try arena.print("cannot read the file ({t})", .{err}));
            return .{};
        },
    };

    const first = problems.items.len;
    const config = try parse(arena, text, problems);
    for (problems.items[first..]) |warning| std.debug.print("mana: config: {s}: {s}\n", .{ config_path, warning });
    return config;
}

const testing = std.testing;

fn expectLanguages(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "parse: empty input gives defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList([]const u8) = .empty;
    const config = try parse(arena.allocator(), "", &warnings);
    try testing.expectEqual(0, warnings.items.len);
    try testing.expectEqual(BackendKind.google, config.backend);
    try testing.expectEqualStrings("tr", config.native);
    try testing.expectEqualStrings("en", config.fallback);
    try expectLanguages(&default_languages, config.languages);
    try testing.expectEqual(null, config.deepl_key);
}

test "parse: full example" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList([]const u8) = .empty;
    const config = try parse(arena.allocator(),
        \\# comment
        \\backend = DeepL
        \\native = de
        \\fallback = fr
        \\languages = en, de, fr, es, it, ru, ar, ja
        \\deepl_key = xxxxxxxx:fx
    , &warnings);
    try testing.expectEqual(0, warnings.items.len);
    try testing.expectEqual(BackendKind.deepl, config.backend);
    try testing.expectEqualStrings("de", config.native);
    try testing.expectEqualStrings("fr", config.fallback);
    try expectLanguages(&.{ "en", "de", "fr", "es", "it", "ru", "ar", "ja" }, config.languages);
    try testing.expectEqualStrings("xxxxxxxx:fx", config.deepl_key.?);
}

test "parse: comments, blank lines, CRLF and extra whitespace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList([]const u8) = .empty;
    const config = try parse(arena.allocator(), "\r\n   # indented comment\r\n\t\r\n  native\t=   ja  \r\nbackend=deepl\r\n", &warnings);
    try testing.expectEqual(0, warnings.items.len);
    try testing.expectEqualStrings("ja", config.native);
    try testing.expectEqual(BackendKind.deepl, config.backend);
}

test "parse: deepl-web backend, either spelling, needs no key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList([]const u8) = .empty;
    const dashed = try parse(arena.allocator(), "backend = DeepL-Web\n", &warnings);
    try testing.expectEqual(BackendKind.deepl_web, dashed.backend);
    try testing.expectEqual(null, dashed.deepl_key);
    const underscored = try parse(arena.allocator(), "backend = deepl_web\n", &warnings);
    try testing.expectEqual(BackendKind.deepl_web, underscored.backend);
    try testing.expectEqual(0, warnings.items.len);
}

test "parse: unknown key and missing = warn with line numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList([]const u8) = .empty;
    const config = try parse(arena.allocator(), "native = de\n\ncolour = blue\njust some words\nfallback = es\n", &warnings);
    try testing.expectEqual(2, warnings.items.len);
    try testing.expect(std.mem.startsWith(u8, warnings.items[0], "line 3: "));
    try testing.expect(std.mem.startsWith(u8, warnings.items[1], "line 4: "));
    try testing.expectEqualStrings("de", config.native);
    try testing.expectEqualStrings("es", config.fallback);
}

test "parse: invalid backend warns and stays google" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList([]const u8) = .empty;
    const config = try parse(arena.allocator(), "backend = bing\n", &warnings);
    try testing.expectEqual(1, warnings.items.len);
    try testing.expect(std.mem.startsWith(u8, warnings.items[0], "line 1: "));
    try testing.expectEqual(BackendKind.google, config.backend);
}

test "parse: languages with stray commas and spaces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList([]const u8) = .empty;
    const config = try parse(arena.allocator(), "languages = ,en,, de ,  ,zh-CN,\n", &warnings);
    try testing.expectEqual(0, warnings.items.len);
    try expectLanguages(&.{ "en", "de", "zh-CN" }, config.languages);
}

test "parse: empty deepl_key is null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList([]const u8) = .empty;
    const config = try parse(arena.allocator(), "deepl_key =   \n", &warnings);
    try testing.expectEqual(0, warnings.items.len);
    try testing.expectEqual(null, config.deepl_key);
}

test "load: missing file gives defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", "/nonexistent/mana-test");
    var problems: std.ArrayList([]const u8) = .empty;
    const config = try load(arena.allocator(), testing.io, &environ, &problems);
    try testing.expectEqualStrings("tr", config.native);
    try testing.expectEqual(0, problems.items.len);
}
