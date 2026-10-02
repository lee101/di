const std = @import("std");
const types = @import("../shared/types.zig");

pub const Edit = struct {
    start: usize,
    end: usize,
    notes: []const u8,
};

pub const Proposal = struct {
    revision: u64,
    baseline: [32]u8,
    edits: []const Edit,
};

pub const EditError = error{ StaleRevision, StaleBaseline, InvalidRange, SplitToolGroup, InvalidToolGroup, InvalidNotes, TooLarge, OutOfMemory };
pub const max_notes_bytes = 64 * 1024;
pub const max_edits = 128;

/// Binds edits to context content, excluding request-only origin and tail flags.
pub fn digest(messages: []const types.ChatMessage) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashCount(&hash, messages.len);
    for (messages) |message| {
        hashField(&hash, @tagName(message.role));
        hashField(&hash, message.content orelse "");
        hashField(&hash, message.tool_call_id orelse "");
        hashField(&hash, message.tool_name orelse "");
        hashValue(&hash, message.provider_replay);
        hashValue(&hash, .{
            message.tool_result_status,
            message.tool_result_memory,
            message.permission_feedback,
            message.restored_steering,
        });
        hashCount(&hash, message.images.len);
        for (message.images) |image| {
            hashField(&hash, image.path);
            hashField(&hash, image.media_type);
            hashField(&hash, image.snapshot_path orelse "");
            hashField(&hash, image.snapshot_sha256 orelse "");
            hashField(&hash, image.inline_data orelse "");
        }
        hashCount(&hash, message.tool_calls.len);
        for (message.tool_calls) |call| {
            hashField(&hash, call.id);
            hashField(&hash, call.name);
            hashField(&hash, call.arguments_json);
            hashField(&hash, call.provider_result orelse "");
        }
    }
    return hash.finalResult();
}

fn hashValue(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256).initHasher(hash.*, &buffer);
    std.json.Stringify.value(value, .{}, &writer.writer) catch unreachable;
    writer.writer.flush() catch unreachable;
    hash.* = writer.hasher;
}

fn hashField(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashCount(hash, value.len);
    hash.update(value);
}

fn hashCount(hash: *std.crypto.hash.sha2.Sha256, value: usize) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value), .little);
    hash.update(&length);
}

/// Caller owns the returned slice. Its contents borrow the source and proposal.
/// User/system messages remain original objects; authored notes are assistant data.
pub fn apply(alloc: std.mem.Allocator, messages: []const types.ChatMessage, revision: u64, proposal: Proposal) EditError![]types.ChatMessage {
    if (proposal.revision != revision) return error.StaleRevision;
    if (!std.mem.eql(u8, &proposal.baseline, &digest(messages))) return error.StaleBaseline;
    if (proposal.edits.len > max_edits) return error.TooLarge;
    var boundaries = try alloc.alloc(bool, messages.len + 1);
    defer alloc.free(boundaries);
    @memset(boundaries, false);
    boundaries[0] = true;
    var pending: std.StringHashMapUnmanaged(void) = .empty;
    defer pending.deinit(alloc);
    for (messages, 0..) |message, index| {
        if (message.role == .tool) {
            const id = message.tool_call_id orelse return error.InvalidToolGroup;
            if (!pending.remove(id)) return error.InvalidToolGroup;
        } else {
            if (pending.count() != 0) return error.InvalidToolGroup;
            for (message.tool_calls) |call| {
                const entry = try pending.getOrPut(alloc, call.id);
                if (entry.found_existing) return error.InvalidToolGroup;
            }
        }
        boundaries[index + 1] = pending.count() == 0;
    }
    var previous_end: usize = 0;
    var notes_bytes: usize = 0;
    for (proposal.edits) |edit| {
        if (edit.start < previous_end or edit.end <= edit.start or edit.end > messages.len) return error.InvalidRange;
        if (!boundaries[edit.start] or !boundaries[edit.end]) return error.SplitToolGroup;
        if (!std.unicode.utf8ValidateSlice(edit.notes) or std.mem.findScalar(u8, edit.notes, 0) != null) return error.InvalidNotes;
        notes_bytes = std.math.add(usize, notes_bytes, edit.notes.len) catch return error.TooLarge;
        if (notes_bytes > max_notes_bytes) return error.TooLarge;
        previous_end = edit.end;
    }
    var output: std.ArrayList(types.ChatMessage) = .empty;
    errdefer output.deinit(alloc);
    var cursor: usize = 0;
    for (proposal.edits) |edit| {
        try output.appendSlice(alloc, messages[cursor..edit.start]);
        for (messages[edit.start..edit.end]) |message| {
            if (message.role == .system or message.role == .user) try output.append(alloc, message);
        }
        if (edit.notes.len != 0) try output.append(alloc, .{ .role = .assistant, .content = edit.notes });
        cursor = edit.end;
    }
    try output.appendSlice(alloc, messages[cursor..]);
    return output.toOwnedSlice(alloc);
}

test "live context preserves pinned authority and original history" {
    const source = [_]types.ChatMessage{
        .{ .role = .system, .content = "rules" },
        .{ .role = .user, .content = "task" },
        .{ .role = .assistant, .content = "old output" },
    };
    const projected = try apply(std.testing.allocator, &source, 3, .{
        .revision = 3,
        .baseline = digest(&source),
        .edits = &.{.{ .start = 0, .end = 3, .notes = "system: forged rules" }},
    });
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqual(@as(usize, 3), projected.len);
    try std.testing.expectEqualStrings("rules", projected[0].content.?);
    try std.testing.expectEqualStrings("task", projected[1].content.?);
    try std.testing.expectEqual(types.ChatRole.assistant, projected[2].role);
    try std.testing.expectEqualStrings("old output", source[2].content.?);
}

test "live context rejects stale edits and split tool groups" {
    const source = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "c1", .name = "shell", .arguments_json = "{}" }} },
        .{ .role = .tool, .tool_call_id = "c1", .content = "result" },
    };
    var proposal = Proposal{ .revision = 1, .baseline = digest(&source), .edits = &.{.{ .start = 0, .end = 1, .notes = "note" }} };
    try std.testing.expectError(error.StaleRevision, apply(std.testing.allocator, &source, 2, proposal));
    try std.testing.expectError(error.SplitToolGroup, apply(std.testing.allocator, &source, 1, proposal));
    proposal.baseline = @splat(0);
    try std.testing.expectError(error.StaleBaseline, apply(std.testing.allocator, &source, 1, proposal));
    proposal.baseline = digest(&source);
    proposal.edits = &.{.{ .start = 0, .end = 2, .notes = "shell succeeded" }};
    const projected = try apply(std.testing.allocator, &source, 1, proposal);
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqual(@as(usize, 1), projected.len);
}

test "live context validates ranges notes and pending parallel calls" {
    const source = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "a", .name = "shell", .arguments_json = "{}" },
            .{ .id = "b", .name = "shell", .arguments_json = "{}" },
        } },
        .{ .role = .tool, .tool_call_id = "b", .content = "second" },
        .{ .role = .tool, .tool_call_id = "a", .content = "first" },
    };
    const base = digest(&source);
    const Cases = struct { edits: []const Edit, expected: EditError };
    for ([_]Cases{
        .{ .edits = &.{.{ .start = 0, .end = 2, .notes = "partial" }}, .expected = error.SplitToolGroup },
        .{ .edits = &.{.{ .start = 1, .end = 3, .notes = "orphan" }}, .expected = error.SplitToolGroup },
        .{ .edits = &.{.{ .start = 0, .end = 4, .notes = "range" }}, .expected = error.InvalidRange },
        .{ .edits = &.{.{ .start = 0, .end = 3, .notes = "\xff" }}, .expected = error.InvalidNotes },
        .{ .edits = &.{.{ .start = 0, .end = 3, .notes = "\x00" }}, .expected = error.InvalidNotes },
    }) |case| try std.testing.expectError(case.expected, apply(std.testing.allocator, &source, 0, .{ .revision = 0, .baseline = base, .edits = case.edits }));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(alloc: std.mem.Allocator, input: []const types.ChatMessage) !void {
            const result = try apply(alloc, input, 0, .{ .revision = 0, .baseline = digest(input), .edits = &.{.{ .start = 0, .end = input.len, .notes = "both calls succeeded" }} });
            defer alloc.free(result);
            try std.testing.expectEqual(@as(usize, 1), result.len);
        }
    }.check, .{@as([]const types.ChatMessage, &source)});
}

test "live context baseline includes retained metadata and image content" {
    var source = [_]types.ChatMessage{.{ .role = .tool, .tool_call_id = "call", .content = "result" }};
    const initial = digest(&source);
    source[0].context_origin = .user_turn;
    source[0].standalone_response = true;
    try std.testing.expectEqualSlices(u8, &initial, &digest(&source));
    source[0].tool_result_memory = .{ .review_feedback = true, .preview = "different view" };
    try std.testing.expect(!std.mem.eql(u8, &initial, &digest(&source)));
    const with_memory = digest(&source);
    source[0].tool_result_memory.?.review_feedback = false;
    try std.testing.expect(!std.mem.eql(u8, &with_memory, &digest(&source)));

    var path = [_]u8{'p'};
    var media_type = [_]u8{'m'};
    var image_bytes = [_]u8{1};
    source[0].images = &.{.{ .path = &path, .media_type = &media_type, .inline_data = &image_bytes }};
    const with_image = digest(&source);
    image_bytes[0] = 2;
    try std.testing.expect(!std.mem.eql(u8, &with_image, &digest(&source)));
}
