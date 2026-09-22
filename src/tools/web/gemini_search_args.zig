const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    query: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = .{ .query = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "gemini_search arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "gemini_search arguments must be an object") };
    }
    if (unknownField(parsed.value.object)) |field| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "gemini_search field \"{s}\" is not supported", .{field}) };
    }

    const query_value = parsed.value.object.get("query") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "gemini_search field \"query\" is required") };
    };
    if (query_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "gemini_search field \"query\" must be a string") };
    }
    const query_len = std.unicode.utf8CountCodepoints(query_value.string) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "gemini_search field \"query\" must be valid UTF-8") };
    };
    if (query_len < 2) {
        return .{ .failure = try ctx.allocator.dupe(u8, "gemini_search field \"query\" must contain at least two characters") };
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .query = try ctx.allocator.dupe(u8, query_value.string) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn unknownField(object: std.json.ObjectMap) ?[]const u8 {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "query")) continue;
        return entry.key_ptr.*;
    }
    return null;
}

fn expectDecodeFailure(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(expected, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            return error.TestExpectedEqual;
        },
    }
}

test "gemini_search decode rejects invalid argument shapes" {
    try expectDecodeFailure("{", "gemini_search arguments must be valid JSON");
    try expectDecodeFailure("[]", "gemini_search arguments must be an object");
    try expectDecodeFailure("{\"query\":\"ok\",\"extra\":true}", "gemini_search field \"extra\" is not supported");
    try expectDecodeFailure("{}", "gemini_search field \"query\" is required");
    try expectDecodeFailure("{\"query\":1}", "gemini_search field \"query\" must be a string");
    try expectDecodeFailure("{\"query\":\"a\"}", "gemini_search field \"query\" must contain at least two characters");
}

test "gemini_search decode owns the query string" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"query\":\"zig allocators\"}");
    defer switch (decoded) {
        .input => |input| input.deinit(alloc),
        .failure => |reason| alloc.free(reason),
    };

    const input = decoded.input.as(Input);
    try std.testing.expectEqualStrings("zig allocators", input.query);
    try std.testing.expect(try validate(.{ .allocator = alloc }, decoded.input) == null);
    try std.testing.expect(readsOnly(decoded.input));
    try std.testing.expect(!isIrreversible(decoded.input));
}
