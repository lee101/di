const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const io_mod = @import("../core/shared/io.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("client.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const credential_authority = @import("../core/auth/credential_authority.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const generation_usage = @import("../core/session/generation_usage_provider.zig");

const Allocator = std.mem.Allocator;

pub const openpaths_base_url = "https://openpaths.io/v1";
pub const openrouter_base_url = "https://openrouter.ai/api/v1";
const openpaths_chat_url = openpaths_base_url ++ "/chat/completions";
const openrouter_chat_url = openrouter_base_url ++ "/chat/completions";
const e2e_endpoint_env = "FX_E2E_OPENPATHS_CHAT_URL";
const max_error_body_bytes: usize = 256 * 1024;
const max_sse_line_bytes: usize = 1024 * 1024;
const max_sse_aggregate_bytes: usize = 64 * 1024 * 1024;
const max_sse_events: usize = 100_000;
const max_tool_calls: usize = 128;
const max_tool_identity_bytes: usize = 1024;
const max_tool_arguments_bytes: usize = 4 * 1024 * 1024;
const max_model_id_bytes: usize = 256;
const max_catalog_bytes: usize = 1024 * 1024;
const fetch_timeout_ms: i64 = 30_000;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;
const max_generation_bytes: usize = 256 * 1024;
const max_generation_id_bytes: usize = 256;
const created_at_seconds_cutoff: i64 = 100_000_000_000;
const unknown_model_label = "unknown";

pub const agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamCompletion,
    .build_request_fn = buildRequestForProvider,
};

fn acceptsSource(source: ?types.CredentialSource) bool {
    return source == .openpaths_api_key or source == .openrouter_api_key;
}

fn validateModel(model: []const u8) !void {
    if (model.len == 0 or model.len > max_model_id_bytes) return error.InvalidOpenPathsModel;
    for (model) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidOpenPathsModel;
    }
}

fn buildRequest(
    alloc: Allocator,
    request: stream_provider.RequestData,
) ![]u8 {
    try request.validatePrompt();
    try validateModel(request.model);
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        _ = budget.deadline;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"messages\":[");
    try writeMessages(writer, alloc, request.instructions, request.messages, request.verified_images);
    try writer.writeByte(']');
    _ = try writeTools(writer, alloc, request.tools);
    try writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, writer);

    if (request.provider_options.reasoning) |effort| {
        try writer.writeAll(",\"reasoning_effort\":");
        try std.json.Stringify.value(effort.label(), .{}, writer);
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_tokens\":{d}", .{limit});
    if (request.response_format) |format| {
        if (format.schema != .object) return error.InvalidStructuredResponseSchema;
        try writer.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
        try writer.writeAll(",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeAll(",\"strict\":false}}");
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn buildRequestForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.RequestData,
) anyerror![]u8 {
    return buildRequest(alloc, request);
}
fn writeMessages(
    writer: *std.Io.Writer,
    alloc: Allocator,
    instructions: []const types.ChatMessage,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    var first = true;
    for (instructions) |message| {
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        try writeComma(writer, &first);
        try writer.writeAll("{\"role\":\"system\",\"content\":");
        try std.json.Stringify.value(text, .{}, writer);
        try writer.writeByte('}');
    }
    for (messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => {
                const text = message.content orelse continue;
                if (text.len == 0) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"system\",\"content\":");
                try std.json.Stringify.value(text, .{}, writer);
                try writer.writeByte('}');
            },
            .user => {
                try writeComma(writer, &first);
                const is_last = message_index == messages.len - 1;
                const images: []const image_attachments.VerifiedSnapshot =
                    if (verified_images) |value| if (is_last) value else &.{} else &.{};
                if (images.len == 0) {
                    try writer.writeAll("{\"role\":\"user\",\"content\":");
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                    try writer.writeByte('}');
                } else {
                    try writer.writeAll("{\"role\":\"user\",\"content\":[");
                    var first_part = true;
                    if (message.content) |content| if (content.len > 0) {
                        try writer.writeAll("{\"type\":\"text\",\"text\":");
                        try std.json.Stringify.value(content, .{}, writer);
                        try writer.writeByte('}');
                        first_part = false;
                    };
                    for (images) |image| {
                        if (!first_part) try writer.writeByte(',');
                        try writeImagePart(writer, alloc, image);
                        first_part = false;
                    }
                    try writer.writeAll("]}");
                }
            },
            .assistant => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"assistant\",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, call_index| {
                        if (call_index != 0) try writer.writeByte(',');
                        try writer.writeAll("{\"id\":");
                        try std.json.Stringify.value(call.id, .{}, writer);
                        try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.value(call.name, .{}, writer);
                        try writer.writeAll(",\"arguments\":");
                        try std.json.Stringify.value(call.arguments_json, .{}, writer);
                        try writer.writeAll("}}");
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .tool => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn writeImagePart(writer: *std.Io.Writer, alloc: Allocator, image: image_attachments.VerifiedSnapshot) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}}");
}

fn writeTools(
    writer: *std.Io.Writer,
    alloc: Allocator,
    tools: stream_provider.ToolSelection,
) !usize {
    var count: usize = 0;
    var tools_out: std.Io.Writer.Allocating = .init(alloc);
    defer tools_out.deinit();
    const tools_writer = &tools_out.writer;

    if (tools.advertised_names.len > 0) {
        for (tools.advertised_names) |name| {
            const function = tools.advertisedFunction(name) orelse {
                // Provider-native advertisements are not OpenPaths function
                // tools. Omit only registered provider-executed tools; missing
                // ordinary schemas fail.
                const registered = tools.registry.lookup(name) orelse return error.InvalidToolSchema;
                if (registered.provider_executed) continue;
                return error.InvalidToolSchema;
            };
            try writeBuiltinTool(tools_writer, alloc, function, count != 0);
            count += 1;
        }
    } else {
        for (tools.advertised_functions) |function| {
            try writeBuiltinTool(tools_writer, alloc, function, count != 0);
            count += 1;
        }
    }
    for (tools.additional_functions) |function| {
        if (tools.advertised_names.len > 0 and containsToolName(tools.advertised_names, function.name)) continue;
        try writeBuiltinTool(tools_writer, alloc, function, count != 0);
        count += 1;
    }
    for (tools.selected_dynamic) |function| {
        if (function.name.len == 0) return error.InvalidToolSchema;
        if (function.input_schema != .object) return error.InvalidToolSchema;
        if (count != 0) try tools_writer.writeByte(',');
        try tools_writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try std.json.Stringify.value(function.name, .{}, tools_writer);
        if (function.description.len > 0) {
            try tools_writer.writeAll(",\"description\":");
            try std.json.Stringify.value(function.description, .{}, tools_writer);
        }
        try tools_writer.writeAll(",\"parameters\":");
        try std.json.Stringify.value(function.input_schema, .{}, tools_writer);
        try tools_writer.writeAll("}}");
        count += 1;
    }
    if (count > 0) {
        try writer.writeAll(",\"tools\":[");
        try writer.writeAll(tools_out.written());
        try writer.writeByte(']');
    }
    return count;
}

fn writeBuiltinTool(
    writer: *std.Io.Writer,
    alloc: Allocator,
    function: model_tool_schema.FunctionSchema,
    comma: bool,
) !void {
    if (function.name.len == 0) return error.InvalidToolSchema;
    if (comma) try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try std.json.Stringify.value(function.name, .{}, writer);
    if (function.description.len > 0) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(function.description, .{}, writer);
    }
    try writer.writeAll(",\"parameters\":");
    try model_tool_schema.writeObjectSchema(alloc, writer, function.input_schema);
    try writer.writeAll("}}");
}

fn containsToolName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

fn streamCompletion(
    _: ?*anyopaque,
    alloc: Allocator,
    request: stream_provider.ModelRequest,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    if (!acceptsSource(request.credential.credentialSource())) return stream_provider.failResult(error.OpenPathsCredentialRequired);
    try validateModel(request.model);
    const payload = request.prepared_request_body orelse
        try buildRequest(alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    var result = streamPrepared(alloc, request, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
        if (requestDeadlineExpired(request)) return stream_provider.failResult(error.Timeout);
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (requestDeadlineExpired(request)) {
        result.deinit(alloc);
        return stream_provider.failResult(error.Timeout);
    }
    return result;
}

fn requestDeadlineExpired(request: stream_provider.ModelRequest) bool {
    const deadline = request.deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

fn chatEndpoint(source: ?types.CredentialSource) ![]const u8 {
    if (io_mod.getenv(e2e_endpoint_env)) |override| {
        if (!gateway_client.isLoopbackHttpUrl(override)) return error.InvalidE2EOpenPathsEndpoint;
        return override;
    }
    return switch (source orelse return error.OpenPathsCredentialRequired) {
        .openpaths_api_key => openpaths_chat_url,
        .openrouter_api_key => openrouter_chat_url,
        else => error.OpenPathsCredentialRequired,
    };
}

pub fn streamPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);
    const api_key = request.credential.secret() orelse
        return stream_provider.failResult(error.OpenPathsCredentialRequired);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
    defer secret.zeroAndFree(alloc, auth_header);
    const endpoint = try chatEndpoint(request.credential.credentialSource());
    const uri = try std.Uri.parse(endpoint);

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = gateway_client.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = auth_header,
        .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
    };
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    if (request.deadline) |deadline| {
        if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) {
            connect_deadline = deadline;
        }
    }
    try request.admission.admit();
    var opened = try gateway_client.openBoundedPost(
        alloc,
        request.cancel_flag,
        connect_deadline,
        &open_operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();
    var cancel_watch: gateway_client.CancelWatch = .{};
    defer cancel_watch.stop();
    if (http_request.connection) |connection|
        try cancel_watch.start(request.cancel_flag, request.deadline, connection.stream_writer.stream);
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const bounded_body = reader.allocRemaining(alloc, .limited(max_error_body_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "OpenPaths error response exceeded the local limit"),
            else => return err,
        };
        const body = if (bounded_body.len > max_error_body_bytes) body: {
            alloc.free(bounded_body);
            break :body try alloc.dupe(u8, "OpenPaths error response exceeded the local limit");
        } else bounded_body;
        return .{
            .failed = .{
                .kind = failureKind(response.head.status),
                .detail = body,
                .ownership = .owned,
            },
        };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var events = request.events;
    const completion = try consumeSse(
        alloc,
        reader,
        &events,
        EventBridge.content,
        EventBridge.toolStart,
        EventBridge.reasoning,
        EventBridge.toolInput,
        request.cancel_flag,
        request.content_capture_limit,
    );
    var completed = completion;
    errdefer {
        var owned = stream_provider.Result{ .completed = .{
            .completion = completed,
            .ownership = .owned,
        } };
        owned.deinit(alloc);
    }
    completed.billing = try billingFromUsage(alloc, request.model, completion.usage);
    const selection = try usageOutcomeFor(
        alloc,
        request.credential,
        completed.billing != null,
        completed.generation_id,
    );
    return .{
        .completed = .{
            .completion = completed,
            .usage = selection.outcome,
            .ownership = .owned,
            .usage_ownership = selection.ownership,
        },
    };
}

const EventBridge = struct {
    fn sink(raw: *anyopaque) *stream_provider.EventSink {
        return @ptrCast(@alignCast(raw));
    }

    fn content(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .content_delta = chunk });
    }

    fn reasoning(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .reasoning_delta = chunk });
    }

    fn toolInput(raw: *anyopaque, chunk: []const u8) void {
        sink(raw).emit(.{ .tool_input_delta = chunk });
    }

    fn toolStart(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8, arguments_json: ?[]const u8) void {
        sink(raw).emit(.{ .tool_started = .{ .id = id, .name = name, .label = label, .arguments_json = arguments_json } });
    }
};

fn failureKind(status: std.http.Status) stream_provider.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

const ToolAccumulator = struct {
    index: i64,
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    started: bool = false,
    arguments: std.ArrayList(u8) = .empty,
    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        if (self.id) |id| alloc.free(id);
        if (self.name) |name| alloc.free(name);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

const SseReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    aggregate_bytes: usize = 0,

    const Line = struct {
        bytes: []const u8,
        wire_bytes: usize,
    };

    fn deinit(self: *SseReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
    }

    fn release(self: *SseReader) void {
        self.pending_line.clearRetainingCapacity();
    }

    fn next(self: *SseReader, alloc: Allocator, reader: anytype) !?[]const u8 {
        while (true) {
            const line = try self.readLine(alloc, reader) orelse return null;
            self.aggregate_bytes = try checkedAccumulatedSize(
                self.aggregate_bytes,
                line.wire_bytes,
                max_sse_aggregate_bytes,
            );
            const trimmed = std.mem.trim(u8, line.bytes, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == ':') {
                self.release();
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "data:")) {
                self.release();
                continue;
            }
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) return null;
            return data;
        }
    }

    fn readLine(self: *SseReader, alloc: Allocator, reader: anytype) !?Line {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.OpenPathsSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) {
                        return error.OpenPathsSseEventTooLarge;
                    }
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            } orelse {
                if (self.pending_line.items.len > 0) {
                    return .{
                        .bytes = self.pending_line.items,
                        .wire_bytes = self.pending_line.items.len,
                    };
                }
                return null;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) {
                return error.OpenPathsSseEventTooLarge;
            }
            if (self.pending_line.items.len == 0) {
                return .{
                    .bytes = fragment,
                    .wire_bytes = fragment.len + 1,
                };
            }
            try self.pending_line.appendSlice(alloc, fragment);
            return .{
                .bytes = self.pending_line.items,
                .wire_bytes = self.pending_line.items.len + 1,
            };
        }
    }
};

fn consumeSse(
    alloc: Allocator,
    reader: anytype,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.ModelCompletion {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var sse: SseReader = .{};
    defer sse.deinit(alloc);
    var finish_reason: ?types.ProviderFinishReason = null;
    var usage: types.Usage = .{};
    var generation_id: ?[]u8 = null;
    errdefer if (generation_id) |id| alloc.free(id);
    var saw_activity = false;
    var event_count: usize = 0;

    while (try sse.next(alloc, reader)) |json_text| {
        defer sse.release();
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        event_count = try checkedAccumulatedSize(event_count, 1, max_sse_events);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        if (parsed.value.object.contains("error")) return error.OpenPathsStreamFailed;

        if (generation_id == null) {
            if (stringField(parsed.value.object, "id")) |id| generation_id = try alloc.dupe(u8, id);
        }
        if (parseUsage(parsed.value.object)) |value| usage = value;

        const choices = parsed.value.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0];
        if (choice != .object) continue;

        if (choice.object.get("delta")) |delta| {
            if (delta == .object) try consumeDelta(
                alloc,
                delta.object,
                callback_ctx,
                on_content_chunk,
                on_tool_start,
                on_reasoning_chunk,
                on_tool_input_chunk,
                content_capture_limit,
                &content,
                &tools,
                &saw_activity,
            );
        }

        if (choice.object.get("finish_reason")) |reason_value| {
            if (reason_value == .string) {
                finish_reason = mapFinishReason(reason_value.string);
            }
        }
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (finish_reason == null and !saw_activity) return error.OpenPathsStreamIncomplete;
    if (finish_reason == null) finish_reason = .stop;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content != null) content = .empty;
    errdefer if (owned_content) |value| alloc.free(value);
    const owned_tools: []types.ToolCall = blk: {
        var completed: std.ArrayList(types.ToolCall) = .empty;
        errdefer completed.deinit(alloc);
        for (tools.items) |*tool| {
            const id = tool.id orelse continue;
            const name = tool.name orelse continue;
            const arguments = if (tool.arguments.items.len > 0)
                try tool.arguments.toOwnedSlice(alloc)
            else
                try alloc.dupe(u8, "{}");
            tool.arguments = .empty;
            try completed.append(alloc, .{
                .id = id,
                .name = name,
                .arguments_json = arguments,
            });
            tool.id = null;
            tool.name = null;
        }
        break :blk try completed.toOwnedSlice(alloc);
    };
    errdefer types.freeToolCallSlice(alloc, owned_tools);
    return .{
        .content = owned_content,
        .tool_calls = owned_tools,
        .generation_id = generation_id,
        .finish_reason = finish_reason.?,
        .usage = usage,
    };
}

fn consumeDelta(
    alloc: Allocator,
    delta: std.json.ObjectMap,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    content_capture_limit: ?usize,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAccumulator),
    saw_activity: *bool,
) !void {
    if (delta.get("content")) |value| {
        if (value == .string and value.string.len > 0) {
            saw_activity.* = true;
            on_content_chunk(callback_ctx, value.string);
            try appendCaptured(alloc, content, value.string, content_capture_limit);
        }
    }
    if (delta.get("reasoning")) |value| {
        if (value == .string and value.string.len > 0) {
            if (on_reasoning_chunk) |callback| callback(callback_ctx, value.string);
        }
    }
    if (delta.get("reasoning_content")) |value| {
        if (value == .string and value.string.len > 0) {
            if (on_reasoning_chunk) |callback| callback(callback_ctx, value.string);
        }
    }
    const tool_calls = delta.get("tool_calls") orelse return;
    if (tool_calls != .array) return;
    for (tool_calls.array.items) |entry| {
        if (entry != .object) continue;
        const index = integerField(entry.object, "index") orelse 0;
        var slot: ?*ToolAccumulator = findTool(tools.items, index);
        if (slot == null) {
            if (tools.items.len >= max_tool_calls) return error.OpenPathsToolCallLimitExceeded;
            try tools.append(alloc, .{ .index = index });
            slot = &tools.items[tools.items.len - 1];
        }
        const tool = slot.?;
        if (entry.object.get("id")) |id_value| {
            if (id_value == .string and id_value.string.len > 0 and tool.id == null) {
                tool.id = try alloc.dupe(u8, id_value.string);
            }
        }
        if (entry.object.get("function")) |function| {
            if (function != .object) continue;
            if (function.object.get("name")) |name_value| {
                if (name_value == .string and name_value.string.len > 0 and tool.name == null) {
                    if (name_value.string.len > max_tool_identity_bytes) {
                        return error.OpenPathsToolCallLimitExceeded;
                    }
                    tool.name = try alloc.dupe(u8, name_value.string);
                }
            }
            if (function.object.get("arguments")) |arguments| {
                if (arguments == .string and arguments.string.len > 0) {
                    try appendToolArguments(alloc, &tool.arguments, arguments.string);
                    saw_activity.* = true;
                    if (on_tool_input_chunk) |callback| callback(callback_ctx, arguments.string);
                }
            }
        }
        if (tool.id != null and tool.name != null and !tool.started) {
            tool.started = true;
            if (on_tool_start) |callback| callback(callback_ctx, tool.id.?, tool.name.?, null, null);
        }
    }
}
pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = "/v1/models",
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

// ---------------------------------------------------------------------------
// Model catalog: OpenAI-compatible GET /models returning {"data":[{"id":...}]}
// ---------------------------------------------------------------------------

fn mapFinishReason(reason: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "length") or std.mem.eql(u8, reason, "max_tokens")) return .length;
    if (std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call")) {
        return .tool_calls;
    }
    if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
    return .other;
}

fn parseUsage(object: std.json.ObjectMap) ?types.Usage {
    const value = object.get("usage") orelse return null;
    if (value != .object) return null;
    const input = unsignedField(value.object, "prompt_tokens");
    const output = unsignedField(value.object, "completion_tokens");
    const cost = costField(value.object, "cost");
    const prompt_details = objectMapField(value.object, "prompt_tokens_details");
    const cache_read = if (prompt_details) |details| unsignedField(details, "cached_tokens") else null;
    const cache_write = if (prompt_details) |details| unsignedField(details, "cache_write_tokens") else null;
    const completion_details = objectMapField(value.object, "completion_tokens_details");
    const reasoning = if (completion_details) |details| unsignedField(details, "reasoning_tokens") else null;
    if (input == null and output == null and cost == null and
        cache_read == null and cache_write == null and reasoning == null) return null;
    return .{
        .input_tokens = input,
        .output_tokens = output,
        .cache_read_tokens = cache_read,
        .cache_write_tokens = cache_write,
        .reasoning_tokens = reasoning,
        .cost = cost,
    };
}

fn objectMapField(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn costField(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    const cost: f64 = switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        .number_string, .string => |text| std.fmt.parseFloat(f64, text) catch return null,
        else => return null,
    };
    if (!std.math.isFinite(cost) or cost < 0) return null;
    return cost;
}

/// Builds the exact-usage billing record when the provider settled the charge.
/// Without a provider-reported cost the billing window must stay incomplete,
/// so this returns null instead of guessing zero.
fn billingFromUsage(
    alloc: Allocator,
    model: []const u8,
    usage: types.Usage,
) !?types.ProviderBilling {
    const cost = usage.cost orelse return null;
    const owned_model = try alloc.dupe(u8, model);
    errdefer alloc.free(owned_model);
    return .{
        .created_at_ms = io_mod.milliTimestamp(),
        .model = owned_model,
        .total_cost = cost,
        .input_tokens = usage.input_tokens orelse 0,
        .output_tokens = usage.output_tokens orelse 0,
        .cache_read_tokens = usage.cache_read_tokens orelse 0,
        .cache_write_tokens = usage.cache_write_tokens orelse 0,
        .reasoning_tokens = usage.reasoning_tokens,
        .billable_web_search_calls = 0,
    };
}

const UsageSelection = struct {
    outcome: stream_provider.UsageOutcome,
    ownership: stream_provider.ResultOwnership,
};

fn usageOutcomeFor(
    alloc: Allocator,
    credential: types.CredentialLease,
    billing_present: bool,
    generation_id: ?[]const u8,
) Allocator.Error!UsageSelection {
    if (billing_present) return .{
        .outcome = .{ .exact = .openpaths },
        .ownership = .borrowed,
    };
    const id = generation_id orelse return .{
        .outcome = .{ .unavailable = .possibly_billed },
        .ownership = .borrowed,
    };
    const source = credential.credentialSource() orelse return .{
        .outcome = .{ .unavailable = .possibly_billed },
        .ownership = .borrowed,
    };
    const scope = generationBase(source) orelse return .{
        .outcome = .{ .unavailable = .possibly_billed },
        .ownership = .borrowed,
    };
    const account_id = credential.accountId();
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_scope = try alloc.dupe(u8, scope);
    errdefer alloc.free(owned_scope);
    const owned_account = if (account_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_account) |value| alloc.free(value);
    return .{
        .outcome = .{ .deferred = .{
            .provider = .openpaths,
            .generation_id = owned_id,
            .scope = owned_scope,
            .tenant = null,
            .account_id = owned_account,
            .credential_source = source,
            .credential_identity = credential_authority.derive(source, account_id),
        } },
        .ownership = .owned,
    };
}

fn generationBase(source: types.CredentialSource) ?[]const u8 {
    return switch (source) {
        .openpaths_api_key => openpaths_base_url,
        .openrouter_api_key => openrouter_base_url,
        else => null,
    };
}

fn appendToolArguments(
    alloc: Allocator,
    arguments: *std.ArrayList(u8),
    delta: []const u8,
) !void {
    _ = checkedAccumulatedSize(arguments.items.len, delta.len, max_tool_arguments_bytes) catch
        return error.OpenPathsToolArgumentsTooLarge;
    try arguments.appendSlice(alloc, delta);
}

fn checkedAccumulatedSize(current: usize, additional: usize, maximum: usize) !usize {
    const next = std.math.add(usize, current, additional) catch
        return error.OpenPathsResourceLimitExceeded;
    if (next > maximum) return error.OpenPathsResourceLimitExceeded;
    return next;
}

fn appendCaptured(
    alloc: Allocator,
    content: *std.ArrayList(u8),
    delta: []const u8,
    limit: ?usize,
) !void {
    const remaining = if (limit) |maximum| maximum -| @min(maximum, content.items.len) else delta.len;
    try content.appendSlice(alloc, delta[0..@min(delta.len, remaining)]);
}

fn findTool(tools: []ToolAccumulator, index: i64) ?*ToolAccumulator {
    for (tools) |*tool| if (tool.index == index) return tool;
    return null;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = integerField(object, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

// ---------------------------------------------------------------------------
// Model catalog: OpenAI-compatible GET /models returning {"data":[{"id":...}]}
// ---------------------------------------------------------------------------

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
};

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    if (!acceptsSource(input.access.credentialSource())) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    const credential = input.access.authorizationCredential() orelse
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };

    const source = input.access.credentialSource().?;
    const request_url = modelsUrl(alloc, source) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .runtime } };
    };
    defer alloc.free(request_url);

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input.cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    var response = fetchBoundedGet(alloc, request_url, credential, cancel_flag, deadline, max_catalog_bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.Cancelled) return .{ .failure = .{ .category = .cancellation } };
        return .{ .failure = .{ .category = .transport, .retryable = true } };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    }
    const catalog = parseCatalog(alloc, response.body) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

const BoundedGetResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *BoundedGetResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const BoundedGetOperation = struct {
    alloc: Allocator,
    url: []const u8,
    credential: []const u8,
    limit: usize,

    pub fn run(self: *@This()) !BoundedGetResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.credential});
        defer secret.zeroAndFree(self.alloc, auth_header);
        const body_buffer = try self.alloc.alloc(u8, self.limit + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.OpenPathsBodyTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > self.limit) return error.OpenPathsBodyTooLarge;
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn fetchBoundedGet(
    alloc: Allocator,
    url: []const u8,
    credential: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    limit: usize,
) !BoundedGetResponse {
    var operation = BoundedGetOperation{
        .alloc = alloc,
        .url = url,
        .credential = credential,
        .limit = limit,
    };
    return gateway_client.runBoundedHttpOperation(
        BoundedGetResponse,
        alloc,
        cancel_flag,
        deadline,
        &operation,
    );
}

fn modelsUrl(alloc: Allocator, source: types.CredentialSource) ![]const u8 {
    if (io_mod.getenv(e2e_endpoint_env)) |_| {
        // The e2e chat override only covers POST /chat/completions; catalogs stay live.
        return switch (source) {
            .openpaths_api_key => std.fmt.allocPrint(alloc, "{s}/models", .{openpaths_base_url}),
            else => std.fmt.allocPrint(alloc, "{s}/models", .{openrouter_base_url}),
        };
    }
    return switch (source) {
        .openpaths_api_key => std.fmt.allocPrint(alloc, "{s}/models", .{openpaths_base_url}),
        else => std.fmt.allocPrint(alloc, "{s}/models", .{openrouter_base_url}),
    };
}

fn parseCatalog(
    alloc: Allocator,
    body: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenPathsModelCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidOpenPathsModelCatalog;
    if (data != .array) return error.InvalidOpenPathsModelCatalog;
    if (data.array.items.len > model_catalog.max_catalog_models) return error.InvalidOpenPathsModelCatalog;

    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    for (data.array.items) |value| {
        if (value != .object) continue;
        const raw_id = stringField(value.object, "id") orelse continue;
        if (raw_id.len == 0 or raw_id.len > max_model_id_bytes) continue;
        const id = try alloc.dupe(u8, raw_id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
            .image_input_claim = imageInputClaim(value.object),
        });
    }
    return catalog;
}

/// Tri-state: true when input_modalities contains "image", false when the array
/// exists without it, null when architecture/modalities data is absent.
fn imageInputClaim(object: std.json.ObjectMap) ?bool {
    const architecture = objectMapField(object, "architecture") orelse return null;
    const modalities_value = architecture.get("input_modalities") orelse return null;
    if (modalities_value != .array) return null;
    for (modalities_value.array.items) |modality| {
        if (modality != .string) continue;
        if (std.mem.eql(u8, modality.string, "image")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Generation usage lookup: OpenRouter-compatible GET /generation?id=<id>
// ---------------------------------------------------------------------------

pub const generation_usage_provider = generation_usage.Provider{
    .context = null,
    .lookup_fn = lookupGenerationUsage,
};

fn lookupGenerationUsage(
    _: ?*anyopaque,
    alloc: Allocator,
    input: generation_usage.LookupInput,
) generation_usage.LookupError!generation_usage.LookupOutcome {
    if (input.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (!isTrustedGenerationOrigin(input.origin)) return .reject;
    const credential = input.credential orelse return .preserve_pending;
    if (credential.len == 0) return .preserve_pending;
    if (input.generation_id.len == 0 or input.generation_id.len > max_generation_id_bytes) {
        return .reject;
    }
    const url = try generationLookupUrl(alloc, input.origin, input.generation_id);
    defer alloc.free(url);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    var response = fetchBoundedGet(
        alloc,
        url,
        credential,
        input.cancel_flag,
        deadline,
        max_generation_bytes,
    ) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf(
                "openpaths",
                "generation usage lookup failed reason={s}",
                .{@errorName(err)},
            );
            return .retry;
        },
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        const outcome = classifyGenerationStatus(response.status);
        debug_trace.logf(
            "openpaths",
            "generation usage lookup status={d} outcome={s}",
            .{ @intFromEnum(response.status), @tagName(outcome) },
        );
        return outcome;
    }
    return parseLookupOutcome(alloc, response.body, input.generation_id);
}

fn isTrustedGenerationOrigin(origin: []const u8) bool {
    return std.mem.eql(u8, origin, openpaths_base_url) or
        std.mem.eql(u8, origin, openrouter_base_url) or
        gateway_client.isLoopbackHttpUrl(origin);
}

fn generationLookupUrl(alloc: Allocator, origin: []const u8, generation_id: []const u8) ![]u8 {
    const encoded = try encodeQueryComponent(alloc, generation_id);
    defer alloc.free(encoded);
    return std.fmt.allocPrint(alloc, "{s}/generation?id={s}", .{ origin, encoded });
}

fn encodeQueryComponent(alloc: Allocator, value: []const u8) ![]u8 {
    const digits = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (value) |byte| {
        if (isUnreservedByte(byte)) {
            try out.append(alloc, byte);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, digits[byte >> 4]);
            try out.append(alloc, digits[byte & 0x0f]);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn isUnreservedByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or
        byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn classifyGenerationStatus(status: std.http.Status) generation_usage.LookupOutcome {
    const code = @intFromEnum(status);
    if (code == 404) return .reject;
    if (code == 408 or code == 425 or code == 429 or code >= 500) return .retry;
    if (status == .unauthorized or status == .forbidden) return .preserve_pending;
    return .reject;
}

fn parseLookupOutcome(
    alloc: Allocator,
    body: []const u8,
    expected_id: []const u8,
) Allocator.Error!generation_usage.LookupOutcome {
    const record = parseGenerationRecord(alloc, body, expected_id, unknown_model_label) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownGeneration => return .reject,
        error.InvalidGenerationRecord => return .preserve_pending,
    };
    return .{ .found = record };
}

const GenerationRecordError = Allocator.Error || error{
    UnknownGeneration,
    InvalidGenerationRecord,
};

/// Parses one authoritative `GET /generation` response leniently: identity and
/// `total_cost` are required, token and timestamp fields degrade to zero. A
/// successful record transfers its strings to `LookupOutcome.found`; callers
/// release them with `LookupOutcome.deinit`.
fn parseGenerationRecord(
    alloc: Allocator,
    body: []const u8,
    expected_id: []const u8,
    requested_model: []const u8,
) GenerationRecordError!generation_usage.Record {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGenerationRecord,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGenerationRecord;
    const data = parsed.value.object.get("data") orelse return error.InvalidGenerationRecord;
    if (data == .null) return error.UnknownGeneration;
    if (data != .object) return error.InvalidGenerationRecord;

    const id_value = data.object.get("id") orelse return error.InvalidGenerationRecord;
    if (id_value != .string) return error.InvalidGenerationRecord;
    if (!std.mem.eql(u8, id_value.string, expected_id)) return error.UnknownGeneration;

    const total_cost = costField(data.object, "total_cost") orelse
        return error.InvalidGenerationRecord;

    const model_source: []const u8 = blk: {
        if (stringField(data.object, "model")) |candidate| {
            validateModel(candidate) catch break :blk requested_model;
            break :blk candidate;
        }
        break :blk requested_model;
    };
    validateModel(model_source) catch return error.InvalidGenerationRecord;

    const details = objectMapField(data.object, "usage_details");
    const created_at_ms = try normalizeCreatedAtMs(integerField(data.object, "created_at"));
    const id = try alloc.dupe(u8, expected_id);
    errdefer alloc.free(id);
    const model = try alloc.dupe(u8, model_source);
    return .{
        .id = id,
        .created_at_ms = created_at_ms,
        .model = model,
        .total_cost = total_cost,
        .input_tokens = usageCount(data.object, details, "native_tokens_prompt", "prompt_tokens") orelse 0,
        .output_tokens = usageCount(data.object, details, "native_tokens_completion", "completion_tokens") orelse 0,
        .cache_read_tokens = usageCount(data.object, details, "native_tokens_cached", "cached_tokens") orelse 0,
        .cache_write_tokens = usageCount(data.object, details, "native_tokens_cache_creation", "cache_creation_tokens") orelse 0,
        .reasoning_tokens = usageCount(data.object, details, "native_tokens_reasoning", "reasoning_tokens"),
        .billable_web_search_calls = 0,
    };
}

fn usageCount(
    data: std.json.ObjectMap,
    details: ?std.json.ObjectMap,
    top_key: []const u8,
    nested_key: []const u8,
) ?u64 {
    const value = data.get(top_key) orelse blk: {
        const map = details orelse return null;
        break :blk map.get(nested_key) orelse return null;
    };
    return switch (value) {
        .integer => |integer| std.math.cast(u64, integer),
        else => null,
    };
}

fn normalizeCreatedAtMs(raw: ?i64) error{InvalidGenerationRecord}!i64 {
    const value = raw orelse return 0;
    if (value < 0) return error.InvalidGenerationRecord;
    if (value < created_at_seconds_cutoff) {
        return std.math.mul(i64, value, 1000) catch return error.InvalidGenerationRecord;
    }
    return value;
}

test "parse catalog keeps every id the models endpoint returns" {
    const body =
        \\{"data":[{"id":"xiaomi/mimo-v2.6-pro"},{"id":"xiaomi/mimo-v2.6-flash"},{"id":"brand-new/vendor-model"},{"id":"zai/glm-5.2"}]}
    ;
    var catalog = try parseCatalog(std.testing.allocator, body);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 4), catalog.items.len);
    try std.testing.expectEqualStrings("xiaomi/mimo-v2.6-pro", catalog.items[0].id);
    try std.testing.expectEqualStrings("xiaomi/mimo-v2.6-flash", catalog.items[1].id);
    try std.testing.expectEqualStrings("brand-new/vendor-model", catalog.items[2].id);
    try std.testing.expectEqualStrings("zai/glm-5.2", catalog.items[3].id);
}

test "parse catalog maps image input modalities to true claims" {
    const body =
        \\{"data":[{"id":"xiaomi/mimo-v2.6-pro","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}},{"id":"xiaomi/mimo-v2.6-flash","architecture":{"input_modalities":["image"]}}]}
    ;
    var catalog = try parseCatalog(std.testing.allocator, body);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqual(@as(?bool, true), catalog.items[0].image_input_claim);
    try std.testing.expectEqual(@as(?bool, true), catalog.items[1].image_input_claim);
}

test "parse catalog maps modality arrays to false claims and missing data to null claims" {
    const body =
        \\{"data":[{"id":"zai/glm-5.2"},{"id":"provider/text-only","architecture":{"input_modalities":["text"]}},{"id":"provider/empty","architecture":{"input_modalities":[]}},{"id":"provider/no-input-key","architecture":{"output_modalities":["text"]}},{"id":"provider/null-architecture","architecture":null},{"id":"provider/non-array-modalities","architecture":{"input_modalities":"text"}}]}
    ;
    var catalog = try parseCatalog(std.testing.allocator, body);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    const expected = [_]?bool{ null, false, false, null, null, null };
    try std.testing.expectEqual(@as(usize, 6), catalog.items.len);
    for (catalog.items, expected) |entry, claim| {
        try std.testing.expectEqual(claim, entry.image_input_claim);
    }
}

test "models url follows the credential source" {
    const alloc = std.testing.allocator;
    const openpaths_url = try modelsUrl(alloc, .openpaths_api_key);
    defer alloc.free(openpaths_url);
    try std.testing.expectEqualStrings("https://openpaths.io/v1/models", openpaths_url);

    const openrouter_url = try modelsUrl(alloc, .openrouter_api_key);
    defer alloc.free(openrouter_url);
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/models", openrouter_url);
}

fn expectOutcomeTag(
    comptime Union: type,
    expected: std.meta.Tag(Union),
    actual: Union,
) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(actual));
}

test "openpaths generation record parses documented cost and token shapes" {
    const alloc = std.testing.allocator;
    const numeric_cost =
        "{\"data\":{\"id\":\"gen_1\",\"total_cost\":0.95,\"native_tokens_prompt\":194,\"native_tokens_completion\":2,\"created_at\":1758000000}}";
    var first: generation_usage.LookupOutcome = .{
        .found = try parseGenerationRecord(alloc, numeric_cost, "gen_1", "xiaomi/mimo-v2.6-pro"),
    };
    defer first.deinit(alloc);
    const record = switch (first) {
        .found => |found| found,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("gen_1", record.id);
    try std.testing.expectEqualStrings("xiaomi/mimo-v2.6-pro", record.model);
    try std.testing.expectEqual(@as(f64, 0.95), record.total_cost);
    try std.testing.expectEqual(@as(u64, 194), record.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), record.output_tokens);
    try std.testing.expectEqual(@as(i64, 1758000000 * 1000), record.created_at_ms);
    try std.testing.expectEqual(@as(u64, 0), record.billable_web_search_calls);

    const string_cost =
        "{\"data\":{\"id\":\"gen_2\",\"model\":\"xiaomi/mimo-v2.6-flash\",\"total_cost\":\"0.25\",\"usage_details\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"reasoning_tokens\":3},\"created_at\":1758000000123}}";
    var second: generation_usage.LookupOutcome = .{
        .found = try parseGenerationRecord(alloc, string_cost, "gen_2", "xiaomi/mimo-v2.6-pro"),
    };
    defer second.deinit(alloc);
    const flash = switch (second) {
        .found => |found| found,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("xiaomi/mimo-v2.6-flash", flash.model);
    try std.testing.expectEqual(@as(f64, 0.25), flash.total_cost);
    try std.testing.expectEqual(@as(u64, 10), flash.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), flash.output_tokens);
    try std.testing.expectEqual(@as(?u64, 3), flash.reasoning_tokens);
    try std.testing.expectEqual(@as(i64, 1758000000123), flash.created_at_ms);
}

test "openpaths generation lookup classifies parse and status outcomes" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnknownGeneration, parseGenerationRecord(
        alloc,
        "{\"data\":{\"id\":\"other\",\"total_cost\":1}}",
        "gen_1",
        "xiaomi/mimo-v2.6-pro",
    ));
    try std.testing.expectError(error.UnknownGeneration, parseGenerationRecord(
        alloc,
        "{\"data\":null}",
        "gen_1",
        "xiaomi/mimo-v2.6-pro",
    ));
    try std.testing.expectError(error.InvalidGenerationRecord, parseGenerationRecord(
        alloc,
        "garbage",
        "gen_1",
        "xiaomi/mimo-v2.6-pro",
    ));
    try std.testing.expectError(error.InvalidGenerationRecord, parseGenerationRecord(
        alloc,
        "{\"data\":{\"id\":\"gen_1\"}}",
        "gen_1",
        "xiaomi/mimo-v2.6-pro",
    ));

    try expectOutcomeTag(generation_usage.LookupOutcome, .reject, classifyGenerationStatus(.not_found));
    try expectOutcomeTag(generation_usage.LookupOutcome, .reject, classifyGenerationStatus(.bad_request));
    try expectOutcomeTag(generation_usage.LookupOutcome, .retry, classifyGenerationStatus(.too_many_requests));
    try expectOutcomeTag(generation_usage.LookupOutcome, .retry, classifyGenerationStatus(.request_timeout));
    try expectOutcomeTag(generation_usage.LookupOutcome, .retry, classifyGenerationStatus(.internal_server_error));
    try expectOutcomeTag(generation_usage.LookupOutcome, .preserve_pending, classifyGenerationStatus(.unauthorized));
    try expectOutcomeTag(generation_usage.LookupOutcome, .preserve_pending, classifyGenerationStatus(.forbidden));
}

test "usage outcome selection prefers exact billing then deferred lookup" {
    const alloc = std.testing.allocator;
    const lease = types.CredentialLease{ .direct = .{
        .secret_bytes = "key",
        .source = .openpaths_api_key,
        .account_id = null,
        .tenant_context = null,
    } };

    const exact = try usageOutcomeFor(alloc, lease, true, "gen_1");
    try expectOutcomeTag(stream_provider.UsageOutcome, .exact, exact.outcome);
    try std.testing.expectEqual(stream_provider.ResultOwnership.borrowed, exact.ownership);

    const deferred = try usageOutcomeFor(alloc, lease, false, "gen_1");
    defer switch (deferred.outcome) {
        .deferred => |reference| {
            alloc.free(@constCast(reference.generation_id));
            alloc.free(@constCast(reference.scope));
            if (reference.account_id) |value| alloc.free(@constCast(value));
        },
        else => {},
    };
    try expectOutcomeTag(stream_provider.UsageOutcome, .deferred, deferred.outcome);
    try std.testing.expectEqual(stream_provider.ResultOwnership.owned, deferred.ownership);
    switch (deferred.outcome) {
        .deferred => |reference| {
            try std.testing.expectEqual(
                @as(std.meta.Tag(@TypeOf(reference.provider)), .openpaths),
                std.meta.activeTag(reference.provider),
            );
            try std.testing.expectEqualStrings("gen_1", reference.generation_id);
            try std.testing.expectEqualStrings(openpaths_base_url, reference.scope);
            try std.testing.expectEqual(@as(?types.CredentialSource, .openpaths_api_key), reference.credential_source);
        },
        else => return error.TestUnexpectedResult,
    }

    const without_id = try usageOutcomeFor(alloc, lease, false, null);
    try expectOutcomeTag(stream_provider.UsageOutcome, .unavailable, without_id.outcome);
    try std.testing.expectEqual(stream_provider.ResultOwnership.borrowed, without_id.ownership);

    const host_managed = try usageOutcomeFor(alloc, .host_managed, false, "gen_1");
    try expectOutcomeTag(stream_provider.UsageOutcome, .unavailable, host_managed.outcome);
}

test "chat completions request uses OpenAI wire shape" {
    const read_file_schema = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read",
        .input_schema = .{},
    };
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "Be concise." }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "Read it." },
        .{
            .role = .assistant,
            .content = "Opening it.",
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" }},
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try buildRequest(std.testing.allocator, .{
        .model = "openpaths/stealth/ox-alpha",
        .instructions = &instructions,
        .tools = .{ .additional_functions = &.{read_file_schema} },
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 4096,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"openpaths/stealth/ox-alpha\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, body, "{\"role\":\"system\",\"content\":\"Be concise.\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function\",\"function\":{\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"max_tokens\":4096") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_effort\"") == null);
}

fn testToolDecode(_: tool_dispatch.DispatchContext, _: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return error.InvalidToolArguments;
}

fn testToolCall(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return error.InvalidToolArguments;
}

fn testToolReadsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

fn testToolIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

const test_provider_executed_tool = tool_dispatch.Tool{
    .name = "web_search",
    .description = "Search the web",
    .model_schema = .{ .name = "web_search", .description = "Search the web" },
    .provider_executed = true,
    .decode = testToolDecode,
    .call = testToolCall,
    .reads_only_fn = testToolReadsOnly,
    .irreversible_fn = testToolIrreversible,
};

const test_unadvertised_tool = tool_dispatch.Tool{
    .name = "ghost",
    .description = "Not registered for advertisement",
    .model_schema = .{ .name = "ghost", .description = "Not registered for advertisement" },
    .decode = testToolDecode,
    .call = testToolCall,
    .reads_only_fn = testToolReadsOnly,
    .irreversible_fn = testToolIrreversible,
};

test "openpaths omits provider-executed advertised tools from requests" {
    const read_file_schema = model_tool_schema.FunctionSchema{
        .name = "read_file",
        .description = "Read",
        .input_schema = .{},
    };
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Read it." }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "xiaomi/mimo-v2.6-pro",
        .messages = &messages,
        .tools = .{
            .registry = .{ .tools = &.{test_provider_executed_tool} },
            .advertised_names = &.{ "web_search", "read_file" },
            .advertised_functions = &.{read_file_schema},
        },
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function\",\"function\":{\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "web_search") == null);
}

const CostCapture = struct {
    fn content(_: *anyopaque, _: []const u8) void {}
};

test "openpaths usage parsing captures cost and cache details" {
    const wire =
        "data: {\"id\":\"gen_9\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hi\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":194,\"completion_tokens\":2,\"cost\":0.95,\"prompt_tokens_details\":{\"cached_tokens\":100,\"cache_write_tokens\":10},\"completion_tokens_details\":{\"reasoning_tokens\":7}}}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(wire);
    var cancelled = std.atomic.Value(bool).init(false);
    var capture: u8 = 0;
    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        @ptrCast(&capture),
        CostCapture.content,
        null,
        null,
        null,
        &cancelled,
        null,
    );
    var owned = stream_provider.Result{ .completed = .{ .completion = completion, .ownership = .owned } };
    defer owned.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u64, 194), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), completion.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 100), completion.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 10), completion.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 7), completion.usage.reasoning_tokens);
    try std.testing.expectEqual(@as(?f64, 0.95), completion.usage.cost.?);

    const billing = (try billingFromUsage(std.testing.allocator, "xiaomi/mimo-v2.6-pro", completion.usage)).?;
    defer std.testing.allocator.free(@constCast(billing.model));
    try std.testing.expectEqualStrings("xiaomi/mimo-v2.6-pro", billing.model);
    try std.testing.expectEqual(@as(f64, 0.95), billing.total_cost);
    try std.testing.expectEqual(@as(u64, 194), billing.input_tokens);
    try std.testing.expectEqual(@as(u64, 2), billing.output_tokens);
    try std.testing.expectEqual(@as(u64, 100), billing.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 10), billing.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 7), billing.reasoning_tokens);
}

test "openpaths billing stays unset without provider-reported cost" {
    const usage = types.Usage{ .input_tokens = 3, .output_tokens = 4 };
    try std.testing.expect((try billingFromUsage(std.testing.allocator, "xiaomi/mimo-v2.6-pro", usage)) == null);

    const negative = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"cost\":-1.0}", .{});
    defer negative.deinit();
    try std.testing.expect(costField(negative.value.object, "cost") == null);

    const numeric_string = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"cost\":\"0.25\"}", .{});
    defer numeric_string.deinit();
    try std.testing.expectEqual(@as(?f64, 0.25), costField(numeric_string.value.object, "cost"));
}

test "openpaths rejects advertised tools without a usable schema" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Read it." }};
    try std.testing.expectError(error.InvalidToolSchema, buildRequest(std.testing.allocator, .{
        .model = "xiaomi/mimo-v2.6-pro",
        .messages = &messages,
        .tools = .{
            .registry = .{ .tools = &.{test_unadvertised_tool} },
            .advertised_names = &.{"ghost"},
        },
        .tool_choice = .auto,
        .provider_options = .{},
    }));
    try std.testing.expectError(error.InvalidToolSchema, buildRequest(std.testing.allocator, .{
        .model = "xiaomi/mimo-v2.6-pro",
        .messages = &messages,
        .tools = .{ .advertised_names = &.{"missing"} },
        .tool_choice = .auto,
        .provider_options = .{},
    }));
}

test "chat completions request serializes reasoning effort and images" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Describe it." }};
    const images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = @constCast(&[_]u8{ 1, 2, 3, 4 }),
        .media_type = "image/png",
    }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "deepseek-v4-flash-vision-exp",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("low") },
        .verified_images = &images,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"reasoning_effort\":\"low\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"image_url\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "data:image/png;base64,AQIDBA==") != null);
}

test "chat completions SSE stream yields deltas tool calls and usage" {
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        tool_inputs: std.ArrayList(u8) = .empty,

        fn append(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, chunk) catch {};
        }

        fn appendToolInput(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tool_inputs.appendSlice(std.testing.allocator, chunk) catch {};
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);
    defer capture.tool_inputs.deinit(std.testing.allocator);
    var cancelled = std.atomic.Value(bool).init(false);

    const wire =
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hel\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_9\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\"}}]},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\":\\\"x\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}\n\n" ++
        "data: [DONE]\n\n";
    var reader: std.Io.Reader = .fixed(wire);

    const completion = try consumeSse(
        std.testing.allocator,
        &reader,
        @ptrCast(&capture),
        Capture.append,
        null,
        null,
        Capture.appendToolInput,
        &cancelled,
        null,
    );

    try std.testing.expectEqualStrings("Hello", capture.content.items);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_9", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", capture.tool_inputs.items);
    try std.testing.expectEqual(@as(?u64, 7), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 3), completion.usage.output_tokens);
    try std.testing.expectEqualStrings("chatcmpl-1", completion.generation_id.?);
    if (completion.content) |content| std.testing.allocator.free(@constCast(content));
    types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
    if (completion.generation_id) |id| std.testing.allocator.free(id);
}
