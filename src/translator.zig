const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Translation = struct {
    text: []const u8,
    source_lang: []const u8,
    target_lang: []const u8,
};

/// A translation service. Each variant carries whatever state its backend
/// needs (e.g. an API key) and implements `translate` in its own namespace.
pub const Backend = union(enum) {
    google,

    pub fn translate(backend: Backend, gpa: Allocator, io: Io, text: []const u8, target_lang: []const u8) !Translation {
        return switch (backend) {
            .google => google.translate(gpa, io, text, target_lang),
        };
    }
};

pub const Options = struct {
    primary_lang: []const u8,
    secondary_lang: []const u8,
    /// Skips the two-way logic and always translates into this language.
    forced_target: ?[]const u8 = null,
};

/// Translates into the primary language, or into the secondary one when the
/// text already is in the primary language.
pub fn translateSmart(backend: Backend, gpa: Allocator, io: Io, text: []const u8, options: Options) !Translation {
    if (options.forced_target) |target| return backend.translate(gpa, io, text, target);

    const first = try backend.translate(gpa, io, text, options.primary_lang);
    if (!sameLanguage(first.source_lang, options.primary_lang)) return first;
    return backend.translate(gpa, io, text, options.secondary_lang);
}

/// Compares only the base language, so "zh-CN" matches "zh".
fn sameLanguage(a: []const u8, b: []const u8) bool {
    const base_a = a[0 .. std.mem.indexOfScalar(u8, a, '-') orelse a.len];
    const base_b = b[0 .. std.mem.indexOfScalar(u8, b, '-') orelse b.len];
    return std.ascii.eqlIgnoreCase(base_a, base_b);
}

const google = struct {
    fn translate(gpa: Allocator, io: Io, text: []const u8, target_lang: []const u8) !Translation {
        var url: Io.Writer.Allocating = .init(gpa);
        try url.writer.print(
            "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&dt=t&tl={s}&q=",
            .{target_lang},
        );
        try std.Uri.Component.percentEncode(&url.writer, text, isUnreserved);

        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();

        var body: Io.Writer.Allocating = .init(gpa);
        const response = try client.fetch(.{
            .location = .{ .url = url.written() },
            .response_writer = &body.writer,
        });
        if (response.status != .ok) {
            std.debug.print("Translation request failed: HTTP {d}\n", .{@backingInt(response.status)});
            return error.TranslationFailed;
        }

        const result = try parseResponse(gpa, body.written());
        return .{ .text = result.text, .source_lang = result.source_lang, .target_lang = target_lang };
    }

    /// Response shape: [[["translated","original",...],...], null, "source-lang", ...]
    fn parseResponse(gpa: Allocator, json: []const u8) !struct { text: []const u8, source_lang: []const u8 } {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, gpa, json, .{});
        if (parsed != .array or parsed.array.items.len < 3) return error.UnexpectedResponse;
        const root = parsed.array.items;
        if (root[0] != .array) return error.UnexpectedResponse;

        var out: Io.Writer.Allocating = .init(gpa);
        for (root[0].array.items) |segment| {
            if (segment != .array or segment.array.items.len == 0) continue;
            const piece = segment.array.items[0];
            if (piece == .string) try out.writer.writeAll(piece.string);
        }

        return .{
            .text = out.written(),
            .source_lang = if (root[2] == .string) root[2].string else "?",
        };
    }

    fn isUnreserved(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
    }
};

test "google.parseResponse joins segments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\[[["Merhaba. ","Hello. ",null,null,10],["Nasılsın?","How are you?",null,null,3]],null,"en"]
    ;
    const result = try google.parseResponse(arena.allocator(), json);
    try std.testing.expectEqualStrings("Merhaba. Nasılsın?", result.text);
    try std.testing.expectEqualStrings("en", result.source_lang);
}
