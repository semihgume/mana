const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Returns the primary selection (text highlighted with the mouse), falling
/// back to the regular clipboard when the primary selection is empty.
pub fn read(gpa: Allocator, io: Io) ![]const u8 {
    const primary = try runWlPaste(gpa, io, &.{ "wl-paste", "--primary", "--no-newline" });
    if (primary.len > 0) return primary;
    return runWlPaste(gpa, io, &.{ "wl-paste", "--no-newline" });
}

fn runWlPaste(gpa: Allocator, io: Io, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    // wl-paste exits non-zero when the selection is empty.
    switch (result.term) {
        .exited => |code| if (code != 0) return "",
        else => return "",
    }
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}
