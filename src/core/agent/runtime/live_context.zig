const std = @import("std");
const compactor = @import("../../compactor/compactor.zig");
const result_store = @import("../../session/result_store.zig");
const types = @import("../../shared/types.zig");
const config_mod = @import("config.zig");

pub const Projection = struct {
    messages: []const types.ChatMessage,
    instructions: []const u8,
};

/// Request-arena owned. Hosts without a writable local session mirror retain
/// their existing context and automatic overflow recovery.
pub fn project(arena: std.mem.Allocator, config: config_mod.Config, messages: []const types.ChatMessage) !?Projection {
    const capability = config.session_child_capability orelse return null;
    if (capability.holdsBlobs()) return null;
    const directory = capability.displayRoutePath(arena, .tool_results) catch return null;
    const path = try std.fs.path.join(arena, &.{ directory, compactor.live_context_mirror.file_name });
    const result = (try compactor.live_context_mirror.refresh(arena, result_store.compactorStore(capability), messages)) orelse return null;
    const quoted_path = try std.json.Stringify.valueAlloc(arena, path, .{});
    const instructions = try std.fmt.allocPrint(
        arena,
        "Model-managed context: {s} mirrors the canonical conversation (system text is omitted). Edit only its edits array with ordinary permitted file or shell tools: {{\"start\":0,\"end\":1,\"notes\":\"concise retained facts\"}} replaces a zero-based half-open message range with assistant notes. Keep the envelope unchanged. User/system messages stay pinned; tool-call groups must stay whole. Edits persist while their source prefix matches, without rewriting history or granting permissions. Retain the objective, unresolved work, concrete evidence, and verification state. Batch stale output into useful notes before the context fills; do not dump the mirror. Existing overflow recovery remains available. Last mirror receipt: {s}.",
        .{ quoted_path, @tagName(result.receipt) },
    );
    return .{ .messages = result.messages, .instructions = instructions };
}
