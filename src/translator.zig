const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Service = enum { google, deepl, deepl_web };

pub const Translation = struct {
    text: []const u8,
    source_lang: []const u8,
    target_lang: []const u8,
    /// Which service actually produced this text.
    service: Service,
    /// Set when a DeepL backend was configured but Google answered: why.
    fell_back: ?Fallback = null,
};

pub const Fallback = enum {
    /// DeepL was asked and failed.
    deepl_failed,
    /// The text is over DeepL's limit (for deepl-web it was never sent).
    too_long,

    fn of(err: anyerror) Fallback {
        return if (err == error.TextTooLong) .too_long else .deepl_failed;
    }
};

/// A translation service. Each variant carries whatever state its backend
/// needs (e.g. an API key) and implements `translate` in its own namespace.
pub const Backend = union(enum) {
    google,
    deepl: struct { key: []const u8 },
    deepl_web,

    pub fn translate(backend: Backend, gpa: Allocator, io: Io, text: []const u8, target_lang: []const u8) !Translation {
        return switch (backend) {
            .google => google.translate(gpa, io, text, target_lang),
            .deepl => |d| deepl.translate(gpa, io, d.key, text, target_lang) catch |err|
                fallBackToGoogle(gpa, io, err, "DeepL", text, target_lang),
            .deepl_web => deepl_web.translate(gpa, io, text, target_lang) catch |err|
                fallBackToGoogle(gpa, io, err, "DeepL web", text, target_lang),
        };
    }
};

/// A sentence for the user about a failed translation. Errors without a
/// sentence of their own keep their name in parentheses, so they stay
/// diagnosable.
pub fn describeError(gpa: Allocator, err: anyerror) Allocator.Error![:0]const u8 {
    return switch (err) {
        // AddressUnavailable: no local IPv6 (or IPv4) address, as when offline.
        error.NetworkDown, error.NetworkUnreachable, error.AddressUnavailable => "No network connection.",
        error.UnknownHostName, error.NameServerFailure, error.NoAddressReturned => "Could not look up the translation service. Is the internet connection working?",
        error.ConnectionRefused, error.HostUnreachable, error.Timeout => "Could not connect to the translation service.",
        error.ConnectionResetByPeer, error.ReadFailed, error.HttpConnectionClosing, error.HttpRequestTruncated => "The connection to the translation service broke off.",
        error.TlsInitializationFailed => "Could not set up a secure connection to the translation service.",
        error.TimedOut => "The translation service did not answer in time.",
        error.TextTooLong => "The text is too long to translate.",
        error.TooManyRequests => "The translation service got too many requests from this computer. Try again later.",
        error.ServiceRefused => "The translation service refused the request.",
        error.ServiceUnavailable => "The translation service is not available right now. Try again later.",
        error.UnexpectedResponse => "The translation service sent an unexpected response.",
        else => gpa.printSentinel("Translation failed ({t}).", .{err}, 0),
    };
}

/// Turns a non-OK HTTP status into an error `describeError` has a sentence for.
fn statusError(status: std.http.Status) error{ TextTooLong, TooManyRequests, ServiceRefused, ServiceUnavailable, UnexpectedResponse } {
    return switch (@backingInt(status)) {
        413, 414 => error.TextTooLong,
        429 => error.TooManyRequests,
        400...412, 415...428, 430...499 => error.ServiceRefused,
        500...599 => error.ServiceUnavailable,
        else => error.UnexpectedResponse,
    };
}

/// Answers a failed DeepL request with Google, except when memory ran out.
fn fallBackToGoogle(gpa: Allocator, io: Io, err: anyerror, name: []const u8, text: []const u8, target_lang: []const u8) !Translation {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    std.debug.print("{s} failed ({t}), falling back to Google\n", .{ name, err });
    var result = try google.translate(gpa, io, text, target_lang);
    result.fell_back = .of(err);
    return result;
}

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
        const url = try gpa.print("https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&dt=t&tl={s}", .{target_lang});
        // The text goes in a form-encoded POST body: in the URL, the server
        // answers HTTP 400 somewhere above 6000 characters.
        var payload: Io.Writer.Allocating = .init(gpa);
        try payload.writer.writeAll("q=");
        try std.Uri.Component.percentEncode(&payload.writer, text, isUnreserved);

        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();

        var body: Io.Writer.Allocating = .init(gpa);
        const response = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload.written(),
            .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
            .response_writer = &body.writer,
        });
        if (response.status != .ok) {
            std.debug.print("Google request failed: HTTP {d}\n", .{@backingInt(response.status)});
            return statusError(response.status);
        }

        const result = try parseResponse(gpa, body.written());
        return .{ .text = result.text, .source_lang = result.source_lang, .target_lang = target_lang, .service = .google };
    }

    /// Response shape: [[["translated","original",...],...], null, "source-lang", ...]
    fn parseResponse(gpa: Allocator, json: []const u8) !struct { text: []const u8, source_lang: []const u8 } {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnexpectedResponse,
        };
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

const deepl = struct {
    fn translate(gpa: Allocator, io: Io, key: []const u8, text: []const u8, target_lang: []const u8) !Translation {
        const payload = try requestBody(gpa, text, try targetCode(gpa, target_lang));
        const authorization = try gpa.print("DeepL-Auth-Key {s}", .{key});

        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();

        var body: Io.Writer.Allocating = .init(gpa);
        const response = try client.fetch(.{
            .location = .{ .url = endpoint(key) },
            .method = .POST,
            .payload = payload,
            .headers = .{
                .authorization = .{ .override = authorization },
                .content_type = .{ .override = "application/json" },
            },
            .response_writer = &body.writer,
        });
        if (response.status != .ok) {
            std.debug.print("DeepL request failed: HTTP {d}\n", .{@backingInt(response.status)});
            return statusError(response.status);
        }

        const result = try parseResponse(gpa, body.written());
        return .{ .text = result.text, .source_lang = result.source_lang, .target_lang = target_lang, .service = .deepl };
    }

    /// Free-plan keys end in ":fx" and must use the free endpoint.
    fn endpoint(key: []const u8) []const u8 {
        return if (std.mem.endsWith(u8, key, ":fx"))
            "https://api-free.deepl.com/v2/translate"
        else
            "https://api.deepl.com/v2/translate";
    }

    /// Maps the app's Google-style code ("en", "zh-CN") to DeepL's ("EN-US", "ZH-HANS").
    fn targetCode(gpa: Allocator, lang: []const u8) ![]const u8 {
        const upper = try std.ascii.allocUpperString(gpa, lang);
        const renames = [_][2][]const u8{
            .{ "EN", "EN-US" },
            .{ "PT", "PT-BR" },
            .{ "ZH-CN", "ZH-HANS" },
            .{ "ZH-TW", "ZH-HANT" },
        };
        for (renames) |rename| {
            if (std.mem.eql(u8, upper, rename[0])) return rename[1];
        }
        return upper;
    }

    /// Request shape: {"text":["..."],"target_lang":"..."}; no source_lang, so DeepL auto-detects.
    fn requestBody(gpa: Allocator, text: []const u8, target_code: []const u8) ![]u8 {
        const Body = struct { text: []const []const u8, target_lang: []const u8 };
        return std.json.Stringify.valueAlloc(gpa, Body{ .text = &.{text}, .target_lang = target_code }, .{});
    }

    /// Response shape: {"translations":[{"detected_source_language":"EN","text":"..."}]}
    fn parseResponse(gpa: Allocator, json: []const u8) !struct { text: []const u8, source_lang: []const u8 } {
        const Response = struct {
            translations: []const struct { detected_source_language: []const u8, text: []const u8 },
        };
        const parsed = std.json.parseFromSliceLeaky(Response, gpa, json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnexpectedResponse,
        };
        if (parsed.translations.len == 0) return error.UnexpectedResponse;
        const first = parsed.translations[0];
        return .{
            .text = first.text,
            .source_lang = try std.ascii.allocLowerString(gpa, first.detected_source_language),
        };
    }
};

/// Keyless DeepL through the "oneshot" endpoint DeepL's own apps use, as the
/// DLX (formerly DeepLX) project does. Unofficial: it may change or break at
/// any time, and DeepL answers HTTP 429 to clients it considers too eager.
/// Request and response have the same JSON shape as the official API.
const deepl_web = struct {
    const endpoint = "https://oneshot-free.www.deepl.com/v1/translate";
    /// Anonymous requests are capped at 1500 UTF-16 code units of text.
    const max_text_len = 1500;

    fn translate(gpa: Allocator, io: Io, text: []const u8, target_lang: []const u8) !Translation {
        const text_len = std.unicode.calcUtf16LeLen(text) catch text.len;
        if (text_len > max_text_len) return error.TextTooLong;
        const payload = try deepl.requestBody(gpa, text, try targetCode(gpa, target_lang));

        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();

        var body: Io.Writer.Allocating = .init(gpa);
        const response = try client.fetch(.{
            .location = .{ .url = endpoint },
            .method = .POST,
            .payload = payload,
            .headers = .{
                // The literal value DeepL's apps send when nobody is logged in.
                .authorization = .{ .override = "None" },
                .content_type = .{ .override = "application/json" },
            },
            .response_writer = &body.writer,
        });
        if (response.status != .ok) {
            std.debug.print("DeepL web request failed: HTTP {d}\n", .{@backingInt(response.status)});
            return statusError(response.status);
        }

        const result = try parseResponse(gpa, body.written());
        try rejectEcho(text, result.text, result.source_lang, target_lang);
        return .{ .text = result.text, .source_lang = result.source_lang, .target_lang = target_lang, .service = .deepl_web };
    }

    /// The endpoint has been seen to answer with the input text unchanged.
    /// That only counts as a translation when the text already is in the
    /// target language.
    fn rejectEcho(input: []const u8, output: []const u8, source_lang: []const u8, target_lang: []const u8) error{EchoedInput}!void {
        const space = " \t\r\n";
        const same_text = std.mem.eql(u8, std.mem.trim(u8, input, space), std.mem.trim(u8, output, space));
        if (same_text and !sameLanguage(source_lang, target_lang)) return error.EchoedInput;
    }

    /// Maps the app's Google-style code to the endpoint's: lowercase language,
    /// uppercase region, regional defaults for "en"/"pt", script names for Chinese
    /// ("en" -> "en-US", "pt-pt" -> "pt-PT", "zh-CN" -> "zh-Hans").
    fn targetCode(gpa: Allocator, lang: []const u8) ![]const u8 {
        const code = try std.ascii.allocLowerString(gpa, lang);
        const renames = [_][2][]const u8{
            .{ "en", "en-US" },
            .{ "pt", "pt-BR" },
            .{ "zh", "zh-Hans" },
            .{ "zh-cn", "zh-Hans" },
            .{ "zh-hans", "zh-Hans" },
            .{ "zh-tw", "zh-Hant" },
            .{ "zh-hant", "zh-Hant" },
        };
        for (renames) |rename| {
            if (std.mem.eql(u8, code, rename[0])) return rename[1];
        }
        if (std.mem.indexOfScalar(u8, code, '-')) |dash| {
            for (code[dash + 1 ..]) |*c| c.* = std.ascii.toUpper(c.*);
        }
        return code;
    }

    /// Same shape as the official API; an empty translation also counts as a failure.
    fn parseResponse(gpa: Allocator, json: []const u8) !struct { text: []const u8, source_lang: []const u8 } {
        const result = try deepl.parseResponse(gpa, json);
        if (result.text.len == 0) return error.UnexpectedResponse;
        return .{ .text = result.text, .source_lang = result.source_lang };
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

test "deepl.parseResponse takes the first translation and lowercases the source" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"translations":[{"detected_source_language":"EN","text":"Merhaba"}]}
    ;
    const result = try deepl.parseResponse(arena.allocator(), json);
    try std.testing.expectEqualStrings("Merhaba", result.text);
    try std.testing.expectEqualStrings("en", result.source_lang);
}

test "deepl.parseResponse rejects empty or malformed responses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectError(error.UnexpectedResponse, deepl.parseResponse(gpa, "{\"translations\":[]}"));
    try std.testing.expectError(error.UnexpectedResponse, deepl.parseResponse(gpa, "{\"message\":\"Wrong endpoint\"}"));
    try std.testing.expectError(error.UnexpectedResponse, deepl.parseResponse(gpa, "{\"translations\":[{\"text\":\"x\"}]}"));
    try std.testing.expectError(error.UnexpectedResponse, deepl.parseResponse(gpa, "not json"));
}

test "deepl.targetCode maps app codes to DeepL codes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqualStrings("TR", try deepl.targetCode(gpa, "tr"));
    try std.testing.expectEqualStrings("DE", try deepl.targetCode(gpa, "de"));
    try std.testing.expectEqualStrings("EN-US", try deepl.targetCode(gpa, "en"));
    try std.testing.expectEqualStrings("PT-BR", try deepl.targetCode(gpa, "pt"));
    try std.testing.expectEqualStrings("ZH-HANS", try deepl.targetCode(gpa, "zh-CN"));
    try std.testing.expectEqualStrings("ZH-HANT", try deepl.targetCode(gpa, "zh-TW"));
}

test "deepl.requestBody escapes the text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body = try deepl.requestBody(arena.allocator(), "say \"hi\"\nnow", "TR");
    try std.testing.expectEqualStrings(
        \\{"text":["say \"hi\"\nnow"],"target_lang":"TR"}
    , body);
}

test "deepl.endpoint picks the free API for :fx keys" {
    try std.testing.expectEqualStrings("https://api-free.deepl.com/v2/translate", deepl.endpoint("abc-123:fx"));
    try std.testing.expectEqualStrings("https://api.deepl.com/v2/translate", deepl.endpoint("abc-123"));
}

test "deepl_web.targetCode maps app codes to the endpoint's codes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqualStrings("tr", try deepl_web.targetCode(gpa, "tr"));
    try std.testing.expectEqualStrings("de", try deepl_web.targetCode(gpa, "DE"));
    try std.testing.expectEqualStrings("en-US", try deepl_web.targetCode(gpa, "en"));
    try std.testing.expectEqualStrings("en-GB", try deepl_web.targetCode(gpa, "en-gb"));
    try std.testing.expectEqualStrings("pt-BR", try deepl_web.targetCode(gpa, "pt"));
    try std.testing.expectEqualStrings("pt-PT", try deepl_web.targetCode(gpa, "pt-PT"));
    try std.testing.expectEqualStrings("zh-Hans", try deepl_web.targetCode(gpa, "zh-CN"));
    try std.testing.expectEqualStrings("zh-Hant", try deepl_web.targetCode(gpa, "zh-TW"));
    try std.testing.expectEqualStrings("es-419", try deepl_web.targetCode(gpa, "es-419"));
}

test "deepl_web request body is the official shape with the endpoint's code" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const body = try deepl.requestBody(gpa, "say \"hi\"\nnow", try deepl_web.targetCode(gpa, "zh-CN"));
    try std.testing.expectEqualStrings(
        \\{"text":["say \"hi\"\nnow"],"target_lang":"zh-Hans"}
    , body);
}

test "deepl_web.parseResponse reads the oneshot response" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"translations":[{"detected_source_language":"en","text":"Merhaba","is_language_detection_confident":false}]}
    ;
    const result = try deepl_web.parseResponse(arena.allocator(), json);
    try std.testing.expectEqualStrings("Merhaba", result.text);
    try std.testing.expectEqualStrings("en", result.source_lang);
}

test "deepl_web.parseResponse rejects empty or malformed responses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectError(error.UnexpectedResponse, deepl_web.parseResponse(gpa, "{\"translations\":[]}"));
    try std.testing.expectError(error.UnexpectedResponse, deepl_web.parseResponse(gpa, "{\"translations\":[{\"detected_source_language\":\"en\",\"text\":\"\"}]}"));
    try std.testing.expectError(error.UnexpectedResponse, deepl_web.parseResponse(gpa, "{\"code\":429,\"message\":\"Too many requests.\"}"));
    try std.testing.expectError(error.UnexpectedResponse, deepl_web.parseResponse(gpa, "not json"));
}

test "deepl_web.rejectEcho: an untranslated answer only passes in the target language" {
    // Echo of English text asked for Turkish: a failure, so Google takes over.
    try std.testing.expectError(error.EchoedInput, deepl_web.rejectEcho("Hello world", "Hello world\n", "en", "tr"));
    // Already Turkish and asked for Turkish: the same text is the right answer.
    try deepl_web.rejectEcho(" Merhaba dünya", "Merhaba dünya", "tr", "tr");
    try deepl_web.rejectEcho("Hello", "Hello", "en", "en-US");
    // A normal translation.
    try deepl_web.rejectEcho("Hello world", "Merhaba dünya", "en", "tr");
}

test "google.parseResponse rejects malformed responses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectError(error.UnexpectedResponse, google.parseResponse(gpa, "<html>Sorry</html>"));
    try std.testing.expectError(error.UnexpectedResponse, google.parseResponse(gpa, "{\"error\":1}"));
    try std.testing.expectError(error.UnexpectedResponse, google.parseResponse(gpa, "[null,null,\"en\"]"));
}

test "statusError sorts HTTP statuses" {
    try std.testing.expectEqual(error.TextTooLong, statusError(.payload_too_large));
    try std.testing.expectEqual(error.TextTooLong, statusError(.uri_too_long));
    try std.testing.expectEqual(error.TooManyRequests, statusError(.too_many_requests));
    try std.testing.expectEqual(error.ServiceRefused, statusError(.forbidden));
    try std.testing.expectEqual(error.ServiceRefused, statusError(@fromBackingInt(456)));
    try std.testing.expectEqual(error.ServiceUnavailable, statusError(.service_unavailable));
    try std.testing.expectEqual(error.UnexpectedResponse, statusError(.found));
}

test describeError {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqualStrings("No network connection.", try describeError(gpa, error.NetworkUnreachable));
    try std.testing.expectEqualStrings("The text is too long to translate.", try describeError(gpa, error.TextTooLong));
    try std.testing.expectEqualStrings("Translation failed (HttpChunkInvalid).", try describeError(gpa, error.HttpChunkInvalid));
}

test "Fallback.of: only a too-long text is told apart" {
    try std.testing.expectEqual(Fallback.too_long, Fallback.of(error.TextTooLong));
    try std.testing.expectEqual(Fallback.deepl_failed, Fallback.of(error.ServiceUnavailable));
    try std.testing.expectEqual(Fallback.deepl_failed, Fallback.of(error.TooManyRequests));
}

test "deepl_web refuses text over its limit before any request" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text: [deepl_web.max_text_len + 1]u8 = @splat('a');
    try std.testing.expectError(error.TextTooLong, deepl_web.translate(arena.allocator(), std.testing.io, &text, "tr"));
}
