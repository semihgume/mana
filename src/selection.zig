const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("c");

/// The application that owns the selection may never answer; give up after this long.
const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } };

/// Text mime types in order of preference.
const text_types = [_][:0]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT" };

/// Returns the primary selection (text highlighted with the mouse), falling
/// back to the regular clipboard when the primary selection is empty.
/// Surrounding whitespace is trimmed, so a blank selection reads as "".
/// Reads through the compositor's ext-data-control protocol, or runs wl-paste
/// when the compositor does not offer it. Returns error.Timeout when the
/// selection's owner does not answer within 3 seconds, error.NotText for data
/// that is not text or not UTF-8 (e.g. an image on the clipboard), and
/// error.FileNotFound when wl-paste is needed but not installed.
pub fn read(gpa: Allocator, io: Io) ![]const u8 {
    const deadline = timeout.toDeadline(io);
    const text = readDataControl(gpa, io, deadline) catch |err| switch (err) {
        error.NoDataControl => try readWlPaste(gpa, io, deadline),
        else => |e| return e,
    };
    if (!std.unicode.utf8ValidateSlice(text)) return error.NotText;
    return text;
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, &std.ascii.whitespace);
}

// ext-data-control lets a client without a window or keyboard focus read the
// selections. One roundtrip binds the globals, a second one delivers the
// current offers; the data then arrives through a pipe from the owner.

/// A selection as the compositor offers it.
const Offer = struct {
    proxy: *c.struct_ext_data_control_offer_v1,
    /// Index into `text_types` of the best text type offered.
    text_type: ?usize = null,
    /// Number of mime types offered, text or not.
    types: usize = 0,

    fn addType(offer: *Offer, mime: []const u8) void {
        offer.types += 1;
        for (text_types, 0..) |text_type, i| {
            if (!std.mem.eql(u8, mime, text_type)) continue;
            if (offer.text_type == null or i < offer.text_type.?) offer.text_type = i;
        }
    }
};

const Session = struct {
    manager: ?*c.struct_ext_data_control_manager_v1 = null,
    seat: ?*c.struct_wl_seat = null,
    /// The offer whose mime types are being announced, before the
    /// selection or primary_selection event that names it.
    pending: ?Offer = null,
    primary: ?Offer = null,
    clipboard: ?Offer = null,

    fn from(data: ?*anyopaque) *Session {
        return @ptrCast(@alignCast(data));
    }

    /// Replaces `slot` with the offer an event named, destroying the old one.
    fn take(session: *Session, slot: *?Offer, id: ?*c.struct_ext_data_control_offer_v1) void {
        if (slot.*) |old| c.ext_data_control_offer_v1_destroy(old.proxy);
        slot.* = null;
        if (session.pending) |pending| {
            if (pending.proxy == id) slot.* = pending;
        }
        session.pending = null;
    }
};

fn readDataControl(gpa: Allocator, io: Io, deadline: Io.Timeout) ![]const u8 {
    const display = c.wl_display_connect(null) orelse return error.NoDataControl;
    defer c.wl_display_disconnect(display);

    var session: Session = .{};
    const registry = c.wl_display_get_registry(display) orelse return error.NoDataControl;
    defer c.wl_registry_destroy(registry);
    _ = c.wl_registry_add_listener(registry, &registry_listener, &session);
    defer if (session.seat) |seat| c.wl_seat_destroy(seat);
    defer if (session.manager) |manager| c.ext_data_control_manager_v1_destroy(manager);
    if (c.wl_display_roundtrip(display) < 0) return error.NoDataControl;

    const device = c.ext_data_control_manager_v1_get_data_device(
        session.manager orelse return error.NoDataControl,
        session.seat orelse return error.NoDataControl,
    ) orelse return error.NoDataControl;
    defer c.ext_data_control_device_v1_destroy(device);
    _ = c.ext_data_control_device_v1_add_listener(device, &device_listener, &session);
    defer for ([_]?Offer{ session.primary, session.clipboard }) |slot| {
        if (slot) |offer| c.ext_data_control_offer_v1_destroy(offer.proxy);
    };
    if (c.wl_display_roundtrip(display) < 0) return error.NoDataControl;

    if (session.primary) |offer| {
        const text = try receive(gpa, io, display, offer, deadline);
        if (text.len > 0) return text;
    }
    if (session.clipboard) |offer| return receive(gpa, io, display, offer, deadline);
    return "";
}

/// Asks the owner for the offer's text and reads it until EOF.
fn receive(gpa: Allocator, io: Io, display: *c.struct_wl_display, offer: Offer, deadline: Io.Timeout) ![]const u8 {
    if (offer.types == 0) return "";
    const text_type = offer.text_type orelse return error.NotText;

    const read_end, const write_end = try pipe();
    defer read_end.close(io);

    c.ext_data_control_offer_v1_receive(offer.proxy, text_types[text_type].ptr, write_end.handle);
    // libwayland sends a copy of the fd, so EOF only arrives once ours is closed.
    write_end.close(io);
    // The owner only learns about the request once it is flushed.
    if (c.wl_display_flush(display) < 0) return error.WaylandFailed;
    return trim(try readAll(gpa, io, read_end, deadline));
}

fn pipe() ![2]Io.File {
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(std.posix.system.pipe2(&fds, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    return .{
        .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
}

/// Reads `file` until EOF, or fails with error.Timeout at `deadline`.
fn readAll(gpa: Allocator, io: Io, file: Io.File, deadline: Io.Timeout) ![]u8 {
    var streams: Io.File.MultiReader.Buffer(1) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(gpa, io, streams.toStreams(), &.{file});
    defer reader.deinit();
    try reader.fillRemaining(deadline);
    try reader.checkAnyError();
    return reader.toOwnedSlice(0);
}

const registry_listener: c.struct_wl_registry_listener = .{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

fn onGlobal(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    _ = version;
    const session = Session.from(data);
    const interface_name = std.mem.span(interface);
    if (session.manager == null and std.mem.eql(u8, interface_name, "ext_data_control_manager_v1")) {
        session.manager = @ptrCast(c.wl_registry_bind(registry, name, &c.ext_data_control_manager_v1_interface, 1));
    } else if (session.seat == null and std.mem.eql(u8, interface_name, "wl_seat")) {
        session.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, 1));
    }
}

fn onGlobalRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

const device_listener: c.struct_ext_data_control_device_v1_listener = .{
    .data_offer = onDataOffer,
    .selection = onSelection,
    .finished = onFinished,
    .primary_selection = onPrimarySelection,
};

const offer_listener: c.struct_ext_data_control_offer_v1_listener = .{
    .offer = onOfferType,
};

fn onDataOffer(data: ?*anyopaque, device: ?*c.struct_ext_data_control_device_v1, id: ?*c.struct_ext_data_control_offer_v1) callconv(.c) void {
    _ = device;
    const session = Session.from(data);
    session.pending = .{ .proxy = id.? };
    _ = c.ext_data_control_offer_v1_add_listener(id, &offer_listener, data);
}

fn onOfferType(data: ?*anyopaque, proxy: ?*c.struct_ext_data_control_offer_v1, mime: [*c]const u8) callconv(.c) void {
    const session = Session.from(data);
    if (session.pending) |*pending| {
        if (pending.proxy == proxy) pending.addType(std.mem.span(mime));
    }
}

fn onSelection(data: ?*anyopaque, device: ?*c.struct_ext_data_control_device_v1, id: ?*c.struct_ext_data_control_offer_v1) callconv(.c) void {
    _ = device;
    const session = Session.from(data);
    session.take(&session.clipboard, id);
}

fn onPrimarySelection(data: ?*anyopaque, device: ?*c.struct_ext_data_control_device_v1, id: ?*c.struct_ext_data_control_offer_v1) callconv(.c) void {
    _ = device;
    const session = Session.from(data);
    session.take(&session.primary, id);
}

fn onFinished(data: ?*anyopaque, device: ?*c.struct_ext_data_control_device_v1) callconv(.c) void {
    _ = data;
    _ = device;
}

// Fallback for compositors without ext-data-control.

fn readWlPaste(gpa: Allocator, io: Io, deadline: Io.Timeout) ![]const u8 {
    const primary = try runWlPaste(gpa, io, deadline, &.{ "wl-paste", "--primary", "--no-newline" });
    if (primary.len > 0) return primary;
    return runWlPaste(gpa, io, deadline, &.{ "wl-paste", "--no-newline" });
}

fn runWlPaste(gpa: Allocator, io: Io, deadline: Io.Timeout, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(gpa, io, .{ .argv = argv, .timeout = deadline });
    // wl-paste exits non-zero when the selection is empty.
    switch (result.term) {
        .exited => |code| if (code != 0) return "",
        else => return "",
    }
    return trim(result.stdout);
}

test "Offer prefers the best text type" {
    var offer: Offer = .{ .proxy = undefined };
    offer.addType("image/png");
    try std.testing.expectEqual(null, offer.text_type);
    offer.addType("TEXT");
    offer.addType("text/plain");
    offer.addType("text/html");
    try std.testing.expectEqualStrings("text/plain", text_types[offer.text_type.?]);
    offer.addType("text/plain;charset=utf-8");
    offer.addType("UTF8_STRING");
    try std.testing.expectEqualStrings("text/plain;charset=utf-8", text_types[offer.text_type.?]);
    try std.testing.expectEqual(6, offer.types);
}

test trim {
    try std.testing.expectEqualStrings("a b", trim(" \t\na b\r\n\x0b\x0c"));
    try std.testing.expectEqualStrings("", trim(" \n "));
}

test "readAll reads past the pipe buffer until EOF" {
    const io = std.testing.io;
    const read_end, const write_end = try pipe();
    defer read_end.close(io);
    const data: [300 * 1024]u8 = @splat('x');
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(file: Io.File, bytes: []const u8) void {
            defer file.close(std.testing.io);
            file.writeStreamingAll(std.testing.io, bytes) catch {};
        }
    }.run, .{ write_end, &data });
    defer writer.join();
    const text = try readAll(std.testing.allocator, io, read_end, timeout.toDeadline(io));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(data.len, text.len);
}

test "readAll gives up when the writer never closes" {
    const io = std.testing.io;
    const read_end, const write_end = try pipe();
    defer read_end.close(io);
    defer write_end.close(io);
    try write_end.writeStreamingAll(io, "partial");
    const short: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } };
    try std.testing.expectError(error.Timeout, readAll(std.testing.allocator, io, read_end, short.toDeadline(io)));
}
