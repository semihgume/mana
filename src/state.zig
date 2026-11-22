//! Machine-written state that survives between runs: the popup position.
//! Deliberately separate from the hand-edited config file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Layer-shell margins (left, top) of a dragged popup.
pub const Position = [2]c_int;

/// `$XDG_STATE_HOME/mana/position`, else `~/.local/state/mana/position`;
/// `null` when neither variable is set.
pub fn positionPath(arena: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    const xdg = environ.get("XDG_STATE_HOME") orelse "";
    if (xdg.len > 0) return try std.fs.path.join(arena, &.{ xdg, "mana", "position" });
    const home = environ.get("HOME") orelse return null;
    return try std.fs.path.join(arena, &.{ home, ".local", "state", "mana", "position" });
}

/// One line, two integers: "left top". Anything else is `null`.
pub fn parsePosition(text: []const u8) ?Position {
    var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var position: Position = undefined;
    for (&position) |*value| {
        value.* = std.fmt.parseInt(c_int, fields.next() orelse return null, 10) catch return null;
    }
    if (fields.next() != null) return null;
    return position;
}

pub fn formatPosition(buffer: []u8, position: Position) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "{d} {d}\n", .{ position[0], position[1] });
}

/// The saved position, or `null` (missing or unreadable file, bad content).
pub fn loadPosition(io: Io, path: []const u8) ?Position {
    var buffer: [64]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, path, &buffer) catch return null;
    return parsePosition(text);
}

/// Saves the position; a failure is reported on stderr and otherwise ignored.
pub fn savePosition(io: Io, path: []const u8, position: Position) void {
    var buffer: [32]u8 = undefined;
    const text = formatPosition(&buffer, position) catch unreachable;
    write(io, path, text) catch |err| std.debug.print("mana: cannot save the position to {s}: {t}\n", .{ path, err });
}

fn write(io: Io, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

const testing = std.testing;

test positionPath {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try testing.expectEqual(null, try positionPath(arena.allocator(), &environ));
    try environ.put("HOME", "/home/u");
    try testing.expectEqualStrings("/home/u/.local/state/mana/position", (try positionPath(arena.allocator(), &environ)).?);
    try environ.put("XDG_STATE_HOME", "");
    try testing.expectEqualStrings("/home/u/.local/state/mana/position", (try positionPath(arena.allocator(), &environ)).?);
    try environ.put("XDG_STATE_HOME", "/s");
    try testing.expectEqualStrings("/s/mana/position", (try positionPath(arena.allocator(), &environ)).?);
}

test parsePosition {
    try testing.expectEqual(Position{ 120, 640 }, parsePosition("120 640\n").?);
    try testing.expectEqual(Position{ -5, 0 }, parsePosition("  -5\t0 \r\n").?);
    try testing.expectEqual(null, parsePosition(""));
    try testing.expectEqual(null, parsePosition("120\n"));
    try testing.expectEqual(null, parsePosition("120 640 7\n"));
    try testing.expectEqual(null, parsePosition("left top\n"));
    try testing.expectEqual(null, parsePosition("1.5 2\n"));
    try testing.expectEqual(null, parsePosition("99999999999 0\n"));
}

test formatPosition {
    var buffer: [32]u8 = undefined;
    const text = try formatPosition(&buffer, .{ 120, 640 });
    try testing.expectEqualStrings("120 640\n", text);
    try testing.expectEqual(Position{ 120, 640 }, parsePosition(text).?);
    const extreme: Position = .{ std.math.minInt(c_int), std.math.maxInt(c_int) };
    try testing.expectEqual(extreme, parsePosition(try formatPosition(&buffer, extreme)).?);
}

test "loadPosition: missing file is null" {
    try testing.expectEqual(null, loadPosition(testing.io, "/nonexistent/mana-test/position"));
}
