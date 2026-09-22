const std = @import("std");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

const acknowledgment = "Thought acknowledged.";

pub const Input = struct {
    thought: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.thought);
        self.* = .{ .thought = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "think arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "think arguments must be an object") };
    }
    if (unknownField(parsed.value.object)) |field| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "think field \"{s}\" is not supported", .{field}) };
    }

    const thought_value = parsed.value.object.get("thought") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "think field \"thought\" is required") };
    };
    if (thought_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "think field \"thought\" must be a string") };
    }
    _ = std.unicode.utf8CountCodepoints(thought_value.string) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "think field \"thought\" must be valid UTF-8") };
    };

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .thought = try ctx.allocator.dupe(u8, thought_value.string) };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

/// The scratchpad keeps no state, so every call succeeds with an acknowledgment.
pub fn call(ctx: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return .{ .success = try ctx.allocator.dupe(u8, acknowledgment) };
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
        if (std.mem.eql(u8, entry.key_ptr.*, "thought")) continue;
        return entry.key_ptr.*;
    }
    return null;
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

fn stackInput(input: *Input) tool_dispatch.ToolInput {
    return .{ .ptr = input, .deinit_fn = noopInputDeinit };
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

test "think decode rejects invalid argument shapes" {
    try expectDecodeFailure("{", "think arguments must be valid JSON");
    try expectDecodeFailure("[]", "think arguments must be an object");
    try expectDecodeFailure(
        "{\"thought\":\"ok\",\"extra\":true}",
        "think field \"extra\" is not supported",
    );
    try expectDecodeFailure("{}", "think field \"thought\" is required");
    try expectDecodeFailure("{\"thought\":1}", "think field \"thought\" must be a string");
}

test "think acknowledges the thought and keeps no state" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"thought\":\"plan the refactor first\"}");
    defer switch (decoded) {
        .input => |input| input.deinit(alloc),
        .failure => |reason| alloc.free(reason),
    };

    const input = decoded.input.as(Input);
    try std.testing.expectEqualStrings("plan the refactor first", input.thought);
    try std.testing.expect(readsOnly(decoded.input));
    try std.testing.expect(!isIrreversible(decoded.input));

    const first = try call(.{ .allocator = alloc }, decoded.input);
    defer alloc.free(first.success);
    const second = try call(.{ .allocator = alloc }, decoded.input);
    defer alloc.free(second.success);
    try std.testing.expectEqualStrings(acknowledgment, first.success);
    try std.testing.expectEqualStrings(acknowledgment, second.success);
}
