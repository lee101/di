const std = @import("std");
const types = @import("../shared/types.zig");
const records = @import("records.zig");
const live = @import("live_context.zig");

pub const file_name = "live-context.json";
const max_document_bytes = 8 * 1024 * 1024;

const MessageView = struct {
    index: usize,
    role: types.ChatRole,
    content: ?[]const u8,
    pinned: bool,
};

const Document = struct {
    version: u8 = 1,
    revision: u64,
    baseline: [32]u8,
    source_count: usize,
    messages: []const MessageView,
    edits: []const live.Edit = &.{},
};

pub const Receipt = enum { unchanged, accepted, stale, invalid };
pub const Result = struct {
    messages: []const types.ChatMessage,
    receipt: Receipt,
};

/// All returned data belongs to `arena`. Storage failure leaves the caller's
/// original context intact and returns null. The canonical history is not edited.
pub fn refresh(arena: std.mem.Allocator, store: records.Store, messages: []const types.ChatMessage) !?Result {
    var edits: []const live.Edit = &.{};
    var projected = messages;
    var revision: u64 = 0;
    var receipt: Receipt = .unchanged;
    const baseline = live.digest(messages);
    const old = store.read(arena, file_name, max_document_bytes + 1) catch |err| switch (err) {
        error.FileNotFound => null,
        error.OutOfMemory => return err,
        error.StoreFailed => return null,
    };
    if (old) |bytes| {
        const document = if (bytes.len <= max_document_bytes)
            std.json.parseFromSliceLeaky(Document, arena, bytes, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            }
        else
            null;
        if (document) |doc| {
            revision = doc.revision;
            if (doc.version != 1 or doc.source_count > messages.len or
                !std.mem.eql(u8, &doc.baseline, if (doc.source_count == messages.len) &baseline else &live.digest(messages[0..doc.source_count])))
            {
                receipt = .stale;
            } else if (doc.edits.len != 0) {
                const prefix = live.apply(arena, messages[0..doc.source_count], doc.revision, .{
                    .revision = doc.revision,
                    .baseline = doc.baseline,
                    .edits = doc.edits,
                }) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => null,
                };
                if (prefix) |accepted| {
                    var combined: std.ArrayList(types.ChatMessage) = .empty;
                    try combined.appendSlice(arena, accepted);
                    try combined.appendSlice(arena, messages[doc.source_count..]);
                    projected = try combined.toOwnedSlice(arena);
                    edits = doc.edits;
                    receipt = .accepted;
                } else receipt = .invalid;
            }
            if (doc.source_count == messages.len and (receipt == .unchanged or receipt == .accepted))
                return .{ .messages = projected, .receipt = receipt };
        } else receipt = .invalid;
    }
    const views = try arena.alloc(MessageView, messages.len);
    for (messages, views, 0..) |message, *view, index| view.* = .{
        .index = index,
        .role = message.role,
        .content = if (message.role == .system) null else message.content,
        .pinned = message.role == .system or message.role == .user,
    };
    var writer: std.Io.Writer.Allocating = .init(arena);
    defer writer.deinit();
    try std.json.Stringify.value(Document{
        .revision = revision +| 1,
        .baseline = baseline,
        .source_count = messages.len,
        .messages = views,
        .edits = edits,
    }, .{}, &writer.writer);
    if (writer.written().len > max_document_bytes) return null;
    store.write(arena, file_name, writer.written()) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    return .{ .messages = projected, .receipt = receipt };
}

test "live context mirror accepts edits preserves growth and rejects changed history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Fake = struct {
        body: ?[]const u8 = null,
        writes: usize = 0,
        const vtable: records.Store.VTable = .{ .read = read, .write = write, .list = list };
        fn read(raw: *anyopaque, a: std.mem.Allocator, _: []const u8, limit: usize) records.Store.Error![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const body = self.body orelse return error.FileNotFound;
            return a.dupe(u8, body[0..@min(body.len, limit)]);
        }
        fn write(raw: *anyopaque, a: std.mem.Allocator, _: []const u8, body: []const u8) records.Store.Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.body = try a.dupe(u8, body);
            self.writes += 1;
        }
        fn list(_: *anyopaque, _: std.mem.Allocator) records.Store.Error![]const []const u8 {
            return &.{};
        }
    };
    var fake = Fake{};
    const store = records.Store{ .context = &fake, .vtable = &Fake.vtable };
    const source = [_]types.ChatMessage{
        .{ .role = .user, .content = "task" },
        .{ .role = .assistant, .content = "long stale output" },
        .{ .role = .user, .content = "next request" },
    };
    const initial = (try refresh(arena, store, source[0..2])).?;
    try std.testing.expectEqual(Receipt.unchanged, initial.receipt);
    for (0..100) |_| _ = try refresh(arena, store, source[0..2]);
    try std.testing.expectEqual(@as(usize, 1), fake.writes);
    var edited = try std.json.parseFromSliceLeaky(Document, arena, fake.body.?, .{});
    edited.edits = &.{.{ .start = 1, .end = 2, .notes = "short notes" }};
    fake.body = try std.json.Stringify.valueAlloc(arena, edited, .{});
    const accepted = (try refresh(arena, store, &source)).?;
    try std.testing.expectEqual(Receipt.accepted, accepted.receipt);
    try std.testing.expectEqualStrings("short notes", accepted.messages[1].content.?);
    try std.testing.expectEqualStrings("next request", accepted.messages[2].content.?);
    const persisted = (try refresh(arena, store, &source)).?;
    try std.testing.expectEqualStrings("short notes", persisted.messages[1].content.?);
    try std.testing.expectEqual(@as(usize, 2), fake.writes);
    var changed = source;
    changed[0].content = "different task";
    const stale = (try refresh(arena, store, &changed)).?;
    try std.testing.expectEqual(Receipt.stale, stale.receipt);
    try std.testing.expectEqualStrings("long stale output", stale.messages[1].content.?);
    fake.body = "not valid JSON";
    const invalid = (try refresh(arena, store, &source)).?;
    try std.testing.expectEqual(Receipt.invalid, invalid.receipt);
    try std.testing.expectEqualStrings("long stale output", invalid.messages[1].content.?);
}
