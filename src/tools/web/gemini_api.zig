const std = @import("std");
const jsonrpc = @import("../../acp/jsonrpc.zig");
const gateway_client = @import("../../gateway/client.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const api_key_env = "GEMINI_API_KEY";
pub const model_env = "FX_GEMINI_SEARCH_MODEL";
pub const base_url_env = "FX_GEMINI_BASE_URL";

pub const default_model = "gemini-2.5-flash";
pub const default_base_url = "https://generativelanguage.googleapis.com";
pub const max_response_bytes: usize = 4 * 1024 * 1024;

/// Named failure taxonomy for the Gemini request path.
pub const GenerateError = error{
    MissingGeminiApiKey,
    InvalidGeminiEndpoint,
    GeminiResponseInvalid,
    GeminiResponseTooLarge,
};

pub const Config = struct {
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
};

pub const Source = struct {
    title: []const u8,
    url: []const u8,

    pub fn deinit(self: Source, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.url);
    }
};

pub const GroundedAnswer = struct {
    answer_text: []const u8,
    sources: []const Source,
    queries: []const []const u8,

    pub fn deinit(self: *GroundedAnswer, alloc: Allocator) void {
        alloc.free(self.answer_text);
        for (self.sources) |source| source.deinit(alloc);
        if (self.sources.len > 0) alloc.free(self.sources);
        for (self.queries) |query| alloc.free(query);
        if (self.queries.len > 0) alloc.free(self.queries);
        self.* = empty();
    }

    pub fn empty() GroundedAnswer {
        return .{ .answer_text = &.{}, .sources = &.{}, .queries = &.{} };
    }
};

pub const ApiError = struct {
    http_status: u16,
    api_status: []const u8 = &.{},
    message: []const u8 = &.{},

    pub fn deinit(self: *ApiError, alloc: Allocator) void {
        if (self.api_status.len > 0) alloc.free(self.api_status);
        if (self.message.len > 0) alloc.free(self.message);
        self.* = .{ .http_status = 0 };
    }
};

pub const Outcome = union(enum) {
    grounded: GroundedAnswer,
    api_error: ApiError,

    pub fn deinit(self: *Outcome, alloc: Allocator) void {
        switch (self.*) {
            .grounded => |*answer| answer.deinit(alloc),
            .api_error => |*api_error| api_error.deinit(alloc),
        }
        self.* = .{ .grounded = GroundedAnswer.empty() };
    }
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = .{ .status = 0, .body = &.{} };
    }
};

/// Injectable HTTP seam so tests can script Gemini responses without network.
pub const Transport = struct {
    ctx: *anyopaque,
    post_json: *const fn (
        ctx: *anyopaque,
        alloc: Allocator,
        url: []const u8,
        api_key: []const u8,
        request_body: []const u8,
    ) anyerror!Response,
};

var default_transport_ctx: u8 = 0;

pub fn defaultTransport() Transport {
    return .{ .ctx = @ptrCast(&default_transport_ctx), .post_json = postJsonDefault };
}

pub fn resolveConfig() Config {
    return .{
        .api_key = io_mod.getenv(api_key_env) orelse "",
        .model = resolveModel(io_mod.getenv(model_env)),
        .base_url = resolveBaseUrl(io_mod.getenv(base_url_env)),
    };
}

pub fn resolveModel(override: ?[]const u8) []const u8 {
    const candidate = override orelse return default_model;
    if (candidate.len == 0) return default_model;
    return candidate;
}

pub fn resolveBaseUrl(override: ?[]const u8) []const u8 {
    const candidate = override orelse return default_base_url;
    if (candidate.len == 0) return default_base_url;
    // The request carries the API key; only a loopback HTTP override is trusted
    // for local testing.
    if (!gateway_client.isLoopbackHttpUrl(candidate)) return default_base_url;
    var trimmed = candidate;
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return if (trimmed.len > 0) trimmed else default_base_url;
}

pub fn requestUrl(alloc: Allocator, model: []const u8, base_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}/v1beta/models/{s}:generateContent", .{ base_url, model });
}

pub fn requestBody(alloc: Allocator, query: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":");
    try jsonrpc.writeJsonStr(query, &out.writer);
    try out.writer.writeAll("}]}],\"tools\":[{\"google_search\":{}}]}");
    return try out.toOwnedSlice();
}

pub fn generateContent(
    alloc: Allocator,
    config: Config,
    query: []const u8,
    transport: Transport,
) anyerror!Outcome {
    if (config.api_key.len == 0) return GenerateError.MissingGeminiApiKey;

    const url = try requestUrl(alloc, config.model, config.base_url);
    defer alloc.free(url);
    const body = try requestBody(alloc, query);
    defer alloc.free(body);

    var response = try transport.post_json(transport.ctx, alloc, url, config.api_key, body);
    defer response.deinit(alloc);

    if (response.status >= 200 and response.status < 300) {
        return .{ .grounded = try parseGroundedResponse(alloc, response.body) };
    }
    return .{ .api_error = try parseApiError(alloc, response.status, response.body) };
}

/// Defensive parsing of a generateContent response: unknown or malformed
/// fields are skipped, web sources are deduplicated by URL, and non-empty
/// search queries are preserved in order.
pub fn parseGroundedResponse(alloc: Allocator, body: []const u8) (GenerateError || Allocator.Error)!GroundedAnswer {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return GenerateError.GeminiResponseInvalid,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return GenerateError.GeminiResponseInvalid;

    var answer_text: std.ArrayList(u8) = .empty;
    errdefer answer_text.deinit(alloc);
    var sources: std.ArrayList(Source) = .empty;
    errdefer deinitSources(alloc, &sources);
    var queries: std.ArrayList([]const u8) = .empty;
    errdefer deinitQueries(alloc, &queries);

    if (parsed.value.object.get("candidates")) |candidates| {
        if (candidates == .array) {
            for (candidates.array.items) |candidate_value| {
                if (candidate_value != .object) continue;
                try appendCandidateText(alloc, &answer_text, candidate_value.object);
                if (candidate_value.object.get("groundingMetadata")) |metadata| {
                    if (metadata == .object) {
                        try appendGroundingChunks(alloc, &sources, metadata.object.get("groundingChunks"));
                        try appendSearchQueries(alloc, &queries, metadata.object.get("webSearchQueries"));
                    }
                }
            }
        }
    }

    return .{
        .answer_text = try answer_text.toOwnedSlice(alloc),
        .sources = try sources.toOwnedSlice(alloc),
        .queries = try queries.toOwnedSlice(alloc),
    };
}

/// Defensive parsing of a Gemini error body: `{"error":{"code", "message", "status"}}`.
pub fn parseApiError(alloc: Allocator, http_status: u16, body: []const u8) Allocator.Error!ApiError {
    var result = ApiError{ .http_status = http_status };
    errdefer result.deinit(alloc);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return result,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return result;
    const error_value = switch (parsed.value.object.get("error") orelse return result) {
        .object => |value| value,
        else => return result,
    };
    if (error_value.get("message")) |message_value| {
        if (message_value == .string and message_value.string.len > 0) {
            result.message = try alloc.dupe(u8, message_value.string);
        }
    }
    if (error_value.get("status")) |status_value| {
        if (status_value == .string and status_value.string.len > 0) {
            result.api_status = try alloc.dupe(u8, status_value.string);
        }
    }
    return result;
}

fn appendCandidateText(
    alloc: Allocator,
    answer_text: *std.ArrayList(u8),
    candidate: std.json.ObjectMap,
) Allocator.Error!void {
    const content = switch (candidate.get("content") orelse return) {
        .object => |value| value,
        else => return,
    };
    const parts = switch (content.get("parts") orelse return) {
        .array => |value| value,
        else => return,
    };
    for (parts.items) |part_value| {
        if (part_value != .object) continue;
        const text_value = part_value.object.get("text") orelse continue;
        if (text_value != .string or text_value.string.len == 0) continue;
        if (answer_text.items.len > 0) try answer_text.appendSlice(alloc, "\n\n");
        try answer_text.appendSlice(alloc, text_value.string);
    }
}

fn appendGroundingChunks(
    alloc: Allocator,
    sources: *std.ArrayList(Source),
    chunks_value: ?std.json.Value,
) Allocator.Error!void {
    const chunks = switch (chunks_value orelse return) {
        .array => |value| value,
        else => return,
    };
    for (chunks.items) |chunk_value| {
        if (chunk_value != .object) continue;
        const web = switch (chunk_value.object.get("web") orelse continue) {
            .object => |value| value,
            else => continue,
        };
        const url_value = web.get("uri") orelse continue;
        if (url_value != .string or !isHttpUrl(url_value.string)) continue;
        if (findSourceByURL(sources.items, url_value.string) != null) continue;

        const title_value = web.get("title");
        const title = if (title_value != null and title_value.? == .string and title_value.?.string.len > 0)
            title_value.?.string
        else
            url_value.string;
        try sources.append(alloc, .{
            .title = try alloc.dupe(u8, title),
            .url = try alloc.dupe(u8, url_value.string),
        });
    }
}

fn appendSearchQueries(
    alloc: Allocator,
    queries: *std.ArrayList([]const u8),
    queries_value: ?std.json.Value,
) Allocator.Error!void {
    const values = switch (queries_value orelse return) {
        .array => |value| value,
        else => return,
    };
    for (values.items) |query_value| {
        if (query_value != .string or query_value.string.len == 0) continue;
        try queries.append(alloc, try alloc.dupe(u8, query_value.string));
    }
}

fn findSourceByURL(sources: []const Source, url: []const u8) ?Source {
    for (sources) |source| {
        if (std.mem.eql(u8, source.url, url)) return source;
    }
    return null;
}

fn isHttpUrl(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or
        std.ascii.startsWithIgnoreCase(url, "https://");
}

fn deinitSources(alloc: Allocator, sources: *std.ArrayList(Source)) void {
    for (sources.items) |source| source.deinit(alloc);
    sources.deinit(alloc);
}

fn deinitQueries(alloc: Allocator, queries: *std.ArrayList([]const u8)) void {
    for (queries.items) |query| alloc.free(query);
    queries.deinit(alloc);
}

fn postJsonDefault(
    _: *anyopaque,
    alloc: Allocator,
    url: []const u8,
    api_key: []const u8,
    request_body: []const u8,
) anyerror!Response {
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const uri = std.Uri.parse(url) catch return GenerateError.InvalidGeminiEndpoint;
    const extra_headers = [_]std.http.Header{.{ .name = "x-goog-api-key", .value = api_key }};
    var request = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
        },
        .extra_headers = &extra_headers,
    });
    defer request.deinit();
    try request.sendBodyComplete(@constCast(request_body));
    var response = try request.receiveHead(&.{});
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = reader.allocRemaining(alloc, .limited(max_response_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return GenerateError.GeminiResponseTooLarge,
        else => return err,
    };
    return .{ .status = @intFromEnum(response.head.status), .body = body };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

test "parses a grounded generateContent response with deduplicated sources" {
    const alloc = std.testing.allocator;
    var answer = try parseGroundedResponse(alloc,
        \\{
        \\ "candidates": [
        \\  {
        \\   "content": {"role": "model", "parts": [
        \\    {"text": "Spain won Euro 2024."},
        \\    {"text": "The final ended 2-1."}
        \\   ]},
        \\   "finishReason": "STOP",
        \\   "groundingMetadata": {
        \\    "groundingChunks": [
        \\     {"web": {"uri": "https://example.com/a", "title": "Example A"}},
        \\     {"web": {"uri": "https://example.com/a", "title": "Duplicate"}},
        \\     {"web": {"uri": "https://example.com/b", "title": ""}},
        \\     {"web": {"uri": "javascript:alert(1)", "title": "Unsafe"}},
        \\     {"retrievedContext": {"uri": "doc-1", "title": "Context"}},
        \\     "not-an-object"
        \\    ],
        \\    "webSearchQueries": ["euro 2024 winner", "", "spain england final"]
        \\   }
        \\  }
        \\ ]
        \\}
    );
    defer answer.deinit(alloc);

    try std.testing.expectEqualStrings("Spain won Euro 2024.\n\nThe final ended 2-1.", answer.answer_text);
    try std.testing.expectEqual(@as(usize, 2), answer.sources.len);
    try std.testing.expectEqualStrings("Example A", answer.sources[0].title);
    try std.testing.expectEqualStrings("https://example.com/a", answer.sources[0].url);
    try std.testing.expectEqualStrings("https://example.com/b", answer.sources[1].title);
    try std.testing.expectEqualStrings("https://example.com/b", answer.sources[1].url);
    try std.testing.expectEqual(@as(usize, 2), answer.queries.len);
    try std.testing.expectEqualStrings("euro 2024 winner", answer.queries[0]);
    try std.testing.expectEqualStrings("spain england final", answer.queries[1]);
}

test "parses a response with empty grounding" {
    const alloc = std.testing.allocator;
    var answer = try parseGroundedResponse(alloc,
        \\{"candidates":[{"content":{"parts":[{"text":"Plain answer."}]},"finishReason":"STOP"}]}
    );
    defer answer.deinit(alloc);

    try std.testing.expectEqualStrings("Plain answer.", answer.answer_text);
    try std.testing.expectEqual(@as(usize, 0), answer.sources.len);
    try std.testing.expectEqual(@as(usize, 0), answer.queries.len);
}

test "rejects malformed response bodies" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.GeminiResponseInvalid, parseGroundedResponse(alloc, "{"));
    try std.testing.expectError(error.GeminiResponseInvalid, parseGroundedResponse(alloc, "[]"));
}

test "parses a Gemini error body defensively" {
    const alloc = std.testing.allocator;
    var api_error = try parseApiError(alloc, 400,
        \\{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}
    );
    defer api_error.deinit(alloc);

    try std.testing.expectEqual(@as(u16, 400), api_error.http_status);
    try std.testing.expectEqualStrings("API key not valid", api_error.message);
    try std.testing.expectEqualStrings("INVALID_ARGUMENT", api_error.api_status);
}

test "tolerates malformed error bodies" {
    const alloc = std.testing.allocator;
    var api_error = try parseApiError(alloc, 502, "<html>bad gateway</html>");
    defer api_error.deinit(alloc);

    try std.testing.expectEqual(@as(u16, 502), api_error.http_status);
    try std.testing.expectEqualStrings("", api_error.message);
    try std.testing.expectEqualStrings("", api_error.api_status);
}

test "builds the generateContent url and grounded request body" {
    const alloc = std.testing.allocator;
    const url = try requestUrl(alloc, "gemini-2.5-flash", default_base_url);
    defer alloc.free(url);
    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
        url,
    );

    const body = try requestBody(alloc, "zig \"allocators\"\nnow");
    defer alloc.free(body);
    try expectContains(body, "\"tools\":[{\"google_search\":{}}]");
    try expectContains(body, "\"role\":\"user\"");
    try expectContains(body, "\"text\":\"zig \\\"allocators\\\"\\nnow\"");
}

test "resolves model and loopback-only base url overrides" {
    try std.testing.expectEqualStrings(default_model, resolveModel(null));
    try std.testing.expectEqualStrings(default_model, resolveModel(""));
    try std.testing.expectEqualStrings("gemini-2.5-pro", resolveModel("gemini-2.5-pro"));

    try std.testing.expectEqualStrings(default_base_url, resolveBaseUrl(null));
    try std.testing.expectEqualStrings(default_base_url, resolveBaseUrl(""));
    try std.testing.expectEqualStrings(default_base_url, resolveBaseUrl("https://gemini.example"));
    try std.testing.expectEqualStrings(default_base_url, resolveBaseUrl("http://evil.example:8080"));
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:43123",
        resolveBaseUrl("http://127.0.0.1:43123/"),
    );
    try std.testing.expectEqualStrings(
        "http://localhost:43123",
        resolveBaseUrl("http://localhost:43123"),
    );
}

const FakeTransport = struct {
    status: u16 = 200,
    body: []const u8 = "{}",
    saw_url: bool = false,
    saw_key: bool = false,
    saw_body: bool = false,
    fail: ?anyerror = null,

    fn transport(self: *@This()) Transport {
        return .{ .ctx = @ptrCast(self), .post_json = postJson };
    }

    fn postJson(
        raw_ctx: *anyopaque,
        alloc: Allocator,
        url: []const u8,
        api_key: []const u8,
        request_body: []const u8,
    ) anyerror!Response {
        const self: *@This() = @ptrCast(@alignCast(raw_ctx));
        if (self.fail) |err| return err;
        self.saw_url = std.mem.find(u8, url, ":generateContent") != null;
        self.saw_key = std.mem.eql(u8, api_key, "test-key");
        self.saw_body = std.mem.find(u8, request_body, "\"google_search\"") != null;
        return .{ .status = self.status, .body = try alloc.dupe(u8, self.body) };
    }
};

test "generateContent drives the transport and returns grounded answers" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .body =
        \\{"candidates":[{"content":{"parts":[{"text":"Grounded."}]},"groundingMetadata":{
        \\ "groundingChunks":[{"web":{"uri":"https://example.com","title":"Example"}}],
        \\ "webSearchQueries":["zig release"]}}]}
    };
    var outcome = try generateContent(alloc, .{
        .api_key = "test-key",
        .model = default_model,
        .base_url = default_base_url,
    }, "zig release", fake.transport());
    defer outcome.deinit(alloc);

    try std.testing.expect(fake.saw_url);
    try std.testing.expect(fake.saw_key);
    try std.testing.expect(fake.saw_body);
    try std.testing.expectEqualStrings("Grounded.", outcome.grounded.answer_text);
    try std.testing.expectEqual(@as(usize, 1), outcome.grounded.sources.len);
    try std.testing.expectEqual(@as(usize, 1), outcome.grounded.queries.len);
}

test "generateContent maps error bodies and missing keys to the error taxonomy" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{
        .status = 400,
        .body = "{\"error\":{\"code\":400,\"message\":\"bad request\",\"status\":\"INVALID_ARGUMENT\"}}",
    };
    var outcome = try generateContent(alloc, .{
        .api_key = "test-key",
        .model = default_model,
        .base_url = default_base_url,
    }, "zig release", fake.transport());
    defer outcome.deinit(alloc);
    try std.testing.expectEqualStrings("bad request", outcome.api_error.message);

    try std.testing.expectError(error.MissingGeminiApiKey, generateContent(alloc, .{
        .api_key = "",
        .model = default_model,
        .base_url = default_base_url,
    }, "zig release", fake.transport()));

    var failing = FakeTransport{ .fail = error.ConnectionRefused };
    try std.testing.expectError(error.ConnectionRefused, generateContent(alloc, .{
        .api_key = "test-key",
        .model = default_model,
        .base_url = default_base_url,
    }, "zig release", failing.transport()));
}
