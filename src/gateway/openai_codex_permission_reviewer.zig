const std = @import("std");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const openai_codex = @import("openai_codex.zig");
const openai_codex_models = @import("openai_codex_models.zig");
const chatgpt_oauth = @import("../core/auth/chatgpt_oauth.zig");
const responses_reviewer = @import("responses_permission_reviewer.zig");

const Allocator = std.mem.Allocator;

pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewCodex,
};

fn reviewCodex(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) anyerror!permission_auto_classifier.ParseOutcome {
    return responses_reviewer.review(alloc, input, request, .{
        .source = .chatgpt_subscription,
        .model = reviewerModel(input),
        .validate_fn = validateCredential,
        .build_fn = openai_codex.buildRequest,
        .send_fn = sendPrepared,
    });
}

/// The `review_model` setting / `FX_REVIEW_MODEL` wins over the catalog-backed
/// default, matching the Gateway reviewer.
fn reviewerModel(input: permission_auto_classifier.ProviderInput) []const u8 {
    if (input.reviewer_model.len > 0) return input.reviewer_model;
    return openai_codex_models.reviewerModelId();
}

fn validateCredential(
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
) !void {
    const account_id = try chatgpt_oauth.extractAccountId(alloc, input.credential);
    alloc.free(account_id);
}

fn sendPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) anyerror!stream_provider.Result {
    return openai_codex.streamPrepared(alloc, request, payload);
}

test "Codex reviewer model prefers the newest catalog entry and honors the override" {
    try std.testing.expectEqualStrings("gpt-6-luna", openai_codex_models.reviewer_model_preferences[0]);
    try std.testing.expectEqualStrings("gpt-5.6-luna", openai_codex_models.reviewer_model_preferences[1]);
    try std.testing.expectEqualStrings("gpt-6-luna", reviewerModel(.{}));
    try std.testing.expectEqualStrings(
        "openai/gpt-5.4",
        reviewerModel(.{ .reviewer_model = "openai/gpt-5.4" }),
    );
}

test "Codex reviewer builds a direct Responses request with the catalog-backed model" {
    const model = openai_codex_models.reviewerModelId();
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "Review the pending action." }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "User requested the change." },
        .{
            .role = .assistant,
            .tool_calls = &.{.{
                .id = "call_review",
                .name = "write_file",
                .arguments_json = "{\"path\":\"a.txt\"}",
            }},
        },
    };
    var cancelled = std.atomic.Value(bool).init(false);
    const body = try responses_reviewer.buildPayloadForTest(
        std.testing.allocator,
        model,
        &instructions,
        &messages,
        "call_review",
        std.Io.Clock.Timestamp.fromNow(@import("../core/shared/io.zig").getIo(), .{
            .clock = .awake,
            .raw = .fromSeconds(5),
        }),
        &cancelled,
        openai_codex.buildRequest,
    );
    defer std.testing.allocator.free(body);

    const expected_model = try std.fmt.allocPrint(std.testing.allocator, "\"model\":\"{s}\"", .{model});
    defer std.testing.allocator.free(expected_model);
    try std.testing.expect(std.mem.find(u8, body, expected_model) != null);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":\"required\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "ai-gateway") == null);
}
