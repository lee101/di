const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const todo_state = @import("../core/session/todo_state.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

const ambiguous_arguments_message =
    "todo field \"op\" is required unless list or items names one operation";
const missing_session_message = "todo requires a live session: no todo state is available";

const field_names = [_][]const u8{ "op", "list", "task", "phase", "items", "reason" };

/// Owned decode of one todo call. `op` stays null when the model omits it, so
/// the state machine can infer the operation from an unambiguous payload.
pub const Input = struct {
    op: ?todo_state.Operation = null,
    list: ?[]todo_state.InitEntry = null,
    list_phases: ?[][]u8 = null,
    list_items: ?[][][]u8 = null,
    task: ?[]u8 = null,
    phase: ?[]u8 = null,
    items: ?[][]u8 = null,
    reason: ?[]u8 = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        if (self.list) |entries| alloc.free(entries);
        if (self.list_phases) |names| {
            for (names) |name| alloc.free(name);
            alloc.free(names);
        }
        if (self.list_items) |groups| {
            for (groups) |group| freeStrings(alloc, group);
            alloc.free(groups);
        }
        if (self.task) |value| alloc.free(value);
        if (self.phase) |value| alloc.free(value);
        if (self.items) |values| freeStrings(alloc, values);
        if (self.reason) |value| alloc.free(value);
        self.* = .{};
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "todo arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "todo arguments must be an object") };
    }
    const object = parsed.value.object;
    if (unknownField(object)) |field| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "todo field \"{s}\" is not supported", .{field}) };
    }

    var owned: Owned = .{ .alloc = ctx.allocator };
    defer owned.deinit();

    if (object.get("op")) |value| {
        switch (try decodeOperation(ctx.allocator, value)) {
            .operation => |operation| owned.op = operation,
            .failure => |reason| return .{ .failure = reason },
        }
    }
    if (object.get("list")) |value| {
        switch (try decodeList(ctx.allocator, value)) {
            .list => |list| {
                owned.list = list.entries;
                owned.list_phases = list.phases;
                owned.list_items = list.items;
            },
            .failure => |reason| return .{ .failure = reason },
        }
    }
    switch (try decodeOptionalString(ctx.allocator, object, "task")) {
        .value => |value| owned.task = value,
        .failure => |reason| return .{ .failure = reason },
    }
    switch (try decodeOptionalString(ctx.allocator, object, "phase")) {
        .value => |value| owned.phase = value,
        .failure => |reason| return .{ .failure = reason },
    }
    if (object.get("items")) |value| {
        switch (try decodeStrings(ctx.allocator, value, "items", 0)) {
            .values => |values| owned.items = values,
            .failure => |reason| return .{ .failure = reason },
        }
    }
    switch (try decodeOptionalString(ctx.allocator, object, "reason")) {
        .value => |value| owned.reason = value,
        .failure => |reason| return .{ .failure = reason },
    }

    const input = try ctx.allocator.create(Input);
    input.* = owned.take();
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

/// Per-operation validation belongs to the state machine: it is the only place
/// that sees the current list, so one request reports every problem at once and
/// leaves the list untouched when any check fails.
pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const session = ctx.session_todo orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, missing_session_message) };
    };
    const input = erased.as(Input);
    // The list outlives this call, so it is owned by the session allocator;
    // only the rendered summary comes from the per-call arena.
    const applied = try session.apply(ctx.lifecycle_allocator, ctx.allocator, io_mod.getIo(), .{
        .op = input.op,
        .list = input.list,
        .task = input.task,
        .phase = input.phase,
        .items = if (input.items) |values| @ptrCast(values) else null,
        .reason = input.reason,
    });
    return switch (applied) {
        .rendered => |summary| .{ .success = summary },
        .ambiguous_operation => .{ .failure = try ctx.allocator.dupe(u8, ambiguous_arguments_message) },
    };
}

/// Only an explicit `view` reads. An omitted `op` can only ever infer `init` or
/// `append`, so a call that has not resolved its operation yet is not a read.
pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return erased.as(Input).op == .view;
}

/// The list is session memory the model owns end to end: every operation is a
/// re-derivable edit of scratch state, never a durable mutation.
pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

/// Partial decode state, released on every path that does not hand it to an
/// `Input`.
const Owned = struct {
    alloc: Allocator,
    op: ?todo_state.Operation = null,
    list: ?[]todo_state.InitEntry = null,
    list_phases: ?[][]u8 = null,
    list_items: ?[][][]u8 = null,
    task: ?[]u8 = null,
    phase: ?[]u8 = null,
    items: ?[][]u8 = null,
    reason: ?[]u8 = null,

    fn deinit(self: *Owned) void {
        var input: Input = .{
            .list = self.list,
            .list_phases = self.list_phases,
            .list_items = self.list_items,
            .task = self.task,
            .phase = self.phase,
            .items = self.items,
            .reason = self.reason,
        };
        input.deinit(self.alloc);
        self.* = .{ .alloc = self.alloc };
    }

    fn take(self: *Owned) Input {
        const input: Input = .{
            .op = self.op,
            .list = self.list,
            .list_phases = self.list_phases,
            .list_items = self.list_items,
            .task = self.task,
            .phase = self.phase,
            .items = self.items,
            .reason = self.reason,
        };
        self.list = null;
        self.list_phases = null;
        self.list_items = null;
        self.task = null;
        self.phase = null;
        self.items = null;
        self.reason = null;
        return input;
    }
};

const OperationDecode = union(enum) {
    operation: ?todo_state.Operation,
    failure: []u8,
};

const StringDecode = union(enum) {
    value: ?[]u8,
    failure: []u8,
};

const StringsDecode = union(enum) {
    values: [][]u8,
    failure: []u8,
};

/// Owned backing storage for one decoded `list`, kept as three parallel arrays
/// so every phase name and task string is freed from exactly one place.
const ListFields = struct {
    entries: []todo_state.InitEntry,
    phases: [][]u8,
    items: [][][]u8,
};

const ListDecode = union(enum) {
    list: ListFields,
    failure: []u8,
};

fn decodeOperation(alloc: Allocator, value: std.json.Value) tool_dispatch.DispatchError!OperationDecode {
    if (value != .string) {
        return .{ .failure = try alloc.dupe(u8, "todo field \"op\" must be a string") };
    }
    if (todo_state.Operation.parse(value.string)) |operation| return .{ .operation = operation };
    return .{ .failure = try std.fmt.allocPrint(alloc, "todo operation \"{s}\" is not supported", .{value.string}) };
}

fn decodeOptionalString(
    alloc: Allocator,
    object: std.json.ObjectMap,
    comptime field: []const u8,
) tool_dispatch.DispatchError!StringDecode {
    const value = object.get(field) orelse return .{ .value = null };
    if (value != .string) {
        return .{ .failure = try std.fmt.allocPrint(alloc, "todo field \"{s}\" must be a string", .{field}) };
    }
    return .{ .value = try alloc.dupe(u8, value.string) };
}

fn decodeStrings(
    alloc: Allocator,
    value: std.json.Value,
    comptime field: []const u8,
    min_items: usize,
) tool_dispatch.DispatchError!StringsDecode {
    if (value != .array) {
        return .{ .failure = try std.fmt.allocPrint(alloc, "todo field \"{s}\" must be an array of strings", .{field}) };
    }
    if (value.array.items.len < min_items) {
        return .{ .failure = try std.fmt.allocPrint(alloc, "todo field \"{s}\" must hold at least {d} item", .{ field, min_items }) };
    }
    const strings = try alloc.alloc([]u8, value.array.items.len);
    var owned: ?[][]u8 = strings;
    var initialized: usize = 0;
    defer {
        if (owned) |values| {
            for (values[0..initialized]) |string| alloc.free(string);
            alloc.free(values);
        }
    }
    for (value.array.items, 0..) |item, index| {
        if (item != .string) {
            return .{ .failure = try std.fmt.allocPrint(alloc, "todo field \"{s}\" item {d} must be a string", .{ field, index }) };
        }
        strings[index] = try alloc.dupe(u8, item.string);
        initialized += 1;
    }
    owned = null;
    return .{ .values = strings };
}

fn decodeList(alloc: Allocator, value: std.json.Value) tool_dispatch.DispatchError!ListDecode {
    if (value != .array) {
        return .{ .failure = try alloc.dupe(u8, "todo field \"list\" must be an array of phase objects") };
    }
    const entries = try alloc.alloc(todo_state.InitEntry, value.array.items.len);
    const phases = try alloc.alloc([]u8, value.array.items.len);
    const items = try alloc.alloc([][]u8, value.array.items.len);
    var owned_entries: ?[]todo_state.InitEntry = entries;
    var owned_phases: ?[][]u8 = phases;
    var owned_items: ?[][][]u8 = items;
    var entry_index: usize = 0;
    defer {
        if (owned_entries) |slice| alloc.free(slice);
        if (owned_phases) |slice| {
            alloc.free(slice);
            for (phases[0..entry_index]) |name| alloc.free(name);
        }
        if (owned_items) |slice| {
            alloc.free(slice);
            for (items[0..entry_index]) |group| freeStrings(alloc, group);
        }
    }
    for (value.array.items, 0..) |item, index| {
        if (item != .object) {
            return .{ .failure = try alloc.dupe(u8, "todo list entry must be an object with phase and items") };
        }
        if (unknownListField(item.object)) |field| {
            return .{ .failure = try std.fmt.allocPrint(alloc, "todo list entry field \"{s}\" is not supported", .{field}) };
        }
        const phase_value = item.object.get("phase") orelse {
            return .{ .failure = try alloc.dupe(u8, "todo list entry field \"phase\" is required") };
        };
        if (phase_value != .string) {
            return .{ .failure = try alloc.dupe(u8, "todo list entry field \"phase\" must be a string") };
        }
        const items_value = item.object.get("items") orelse {
            return .{ .failure = try alloc.dupe(u8, "todo list entry field \"items\" is required") };
        };
        const contents = switch (try decodeStrings(alloc, items_value, "items", 1)) {
            .failure => |reason| return .{ .failure = reason },
            .values => |values| values,
        };
        phases[index] = try alloc.dupe(u8, phase_value.string);
        items[index] = contents;
        entries[index] = .{ .phase = phases[index], .items = @ptrCast(contents) };
        entry_index = index + 1;
    }
    owned_entries = null;
    owned_phases = null;
    owned_items = null;
    return .{ .list = .{ .entries = entries, .phases = phases, .items = items } };
}

fn freeStrings(alloc: Allocator, strings: [][]u8) void {
    for (strings) |string| alloc.free(string);
    alloc.free(strings);
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn unknownField(object: std.json.ObjectMap) ?[]const u8 {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        for (field_names) |name| {
            if (std.mem.eql(u8, key, name)) break;
        } else {
            return key;
        }
    }
    return null;
}

fn unknownListField(object: std.json.ObjectMap) ?[]const u8 {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "phase") or std.mem.eql(u8, key, "items")) continue;
        return key;
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

fn expectDecodeInput(args_json: []const u8) !tool_dispatch.ToolInput {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    return switch (decoded) {
        .failure => |body| {
            alloc.free(body);
            return error.TestExpectedEqual;
        },
        .input => |input| input,
    };
}

fn dispatchContext(alloc: Allocator, session: ?*todo_state.Session) tool_dispatch.DispatchContext {
    return .{ .allocator = alloc, .lifecycle_allocator = alloc, .session_todo = session };
}

/// Decodes and calls one request with the per-call result allocator and the
/// session state allocator separated, the way a real dispatch context does.
fn runCallIn(result_alloc: Allocator, state_alloc: Allocator, session: ?*todo_state.Session, args_json: []const u8) !tool_dispatch.ToolResult {
    const context = tool_dispatch.DispatchContext{
        .allocator = result_alloc,
        .lifecycle_allocator = state_alloc,
        .session_todo = session,
    };
    const decoded = try decode(context, args_json);
    const input = switch (decoded) {
        .failure => |body| {
            result_alloc.free(body);
            return error.TestExpectedEqual;
        },
        .input => |value| value,
    };
    defer input.deinit(result_alloc);
    return call(context, input);
}

/// Decodes and calls one request against a session, returning the result the
/// model would see.
fn runCall(alloc: Allocator, session: ?*todo_state.Session, args_json: []const u8) !tool_dispatch.ToolResult {
    const decoded = try decode(dispatchContext(alloc, session), args_json);
    const input = switch (decoded) {
        .failure => |body| {
            alloc.free(body);
            return error.TestExpectedEqual;
        },
        .input => |value| value,
    };
    defer input.deinit(alloc);
    return call(dispatchContext(alloc, session), input);
}

fn expectSuccessText(alloc: Allocator, session: ?*todo_state.Session, args_json: []const u8, expected: []const u8) !void {
    const result = try runCall(alloc, session, args_json);
    const body = switch (result) {
        .success => |text| text,
        .failure, .rich => return error.TestUnexpectedResult,
    };
    defer alloc.free(body);
    try std.testing.expectEqualStrings(expected, body);
}

fn expectFailureText(alloc: Allocator, session: ?*todo_state.Session, args_json: []const u8, expected: []const u8) !void {
    const result = try runCall(alloc, session, args_json);
    const body = switch (result) {
        .failure => |text| text,
        .success, .rich => return error.TestUnexpectedResult,
    };
    defer alloc.free(body);
    try std.testing.expectEqualStrings(expected, body);
}

test "todo decode rejects invalid argument shapes" {
    try expectDecodeFailure("{", "todo arguments must be valid JSON");
    try expectDecodeFailure("[]", "todo arguments must be an object");
    try expectDecodeFailure(
        "{\"op\":\"view\",\"ops\":[]}",
        "todo field \"ops\" is not supported",
    );
    try expectDecodeFailure("{\"op\":1}", "todo field \"op\" must be a string");
    try expectDecodeFailure("{\"op\":\"complete\"}", "todo operation \"complete\" is not supported");
    try expectDecodeFailure("{\"task\":1}", "todo field \"task\" must be a string");
    try expectDecodeFailure("{\"phase\":[]}", "todo field \"phase\" must be a string");
    try expectDecodeFailure("{\"reason\":2}", "todo field \"reason\" must be a string");
    try expectDecodeFailure("{\"items\":\"Run tests\"}", "todo field \"items\" must be an array of strings");
    try expectDecodeFailure(
        "{\"items\":[\"Run tests\",7]}",
        "todo field \"items\" item 1 must be a string",
    );
}

test "todo decode rejects invalid list shapes" {
    try expectDecodeFailure(
        "{\"op\":\"init\",\"list\":{}}",
        "todo field \"list\" must be an array of phase objects",
    );
    try expectDecodeFailure(
        "{\"op\":\"init\",\"list\":[\"Foundation\"]}",
        "todo list entry must be an object with phase and items",
    );
    try expectDecodeFailure(
        "{\"op\":\"init\",\"list\":[{\"phase\":\"Foundation\",\"items\":[\"Wire\"],\"owner\":\"me\"}]}",
        "todo list entry field \"owner\" is not supported",
    );
    try expectDecodeFailure(
        "{\"op\":\"init\",\"list\":[{\"items\":[\"Wire\"]}]}",
        "todo list entry field \"phase\" is required",
    );
    try expectDecodeFailure(
        "{\"op\":\"init\",\"list\":[{\"phase\":1,\"items\":[\"Wire\"]}]}",
        "todo list entry field \"phase\" must be a string",
    );
    try expectDecodeFailure(
        "{\"op\":\"init\",\"list\":[{\"phase\":\"Foundation\"}]}",
        "todo list entry field \"items\" is required",
    );
    try expectDecodeFailure(
        "{\"op\":\"init\",\"list\":[{\"phase\":\"Foundation\",\"items\":[]}]}",
        "todo field \"items\" must hold at least 1 item",
    );
    try expectDecodeFailure(
        "{\"op\":\"init\",\"list\":[{\"phase\":\"Foundation\",\"items\":[3]}]}",
        "todo field \"items\" item 0 must be a string",
    );
}

test "todo decode owns every accepted argument" {
    const alloc = std.testing.allocator;
    const input = try expectDecodeInput(
        \\{"op":"block","list":[{"phase":"Foundation","items":["Scaffold crate","Wire workspace"]},
        \\{"phase":"Verification","items":["Run tests"]}],"task":"Run tests","phase":"Verification",
        \\"items":["Handle retries"],"reason":"awaiting review"}
    );
    defer input.deinit(alloc);

    const decoded = input.as(Input);
    try std.testing.expectEqual(todo_state.Operation.block, decoded.op.?);
    try std.testing.expectEqual(@as(usize, 2), decoded.list.?.len);
    try std.testing.expectEqualStrings("Foundation", decoded.list.?[0].phase);
    try std.testing.expectEqualStrings("Wire workspace", decoded.list.?[0].items[1]);
    try std.testing.expectEqualStrings("Verification", decoded.list.?[1].phase);
    try std.testing.expectEqualStrings("Run tests", decoded.list.?[1].items[0]);
    try std.testing.expectEqualStrings("Run tests", decoded.task.?);
    try std.testing.expectEqualStrings("Verification", decoded.phase.?);
    try std.testing.expectEqualStrings("Handle retries", decoded.items.?[0]);
    try std.testing.expectEqualStrings("awaiting review", decoded.reason.?);
}

test "todo decode leaves an omitted operation unresolved" {
    const alloc = std.testing.allocator;
    const input = try expectDecodeInput(
        "{\"list\":[{\"phase\":\"Foundation\",\"items\":[\"Scaffold crate\"]}]}",
    );
    defer input.deinit(alloc);
    try std.testing.expect(input.as(Input).op == null);
}

test "todo marks only an explicit view as a read" {
    const alloc = std.testing.allocator;
    const view = try expectDecodeInput("{\"op\":\"view\"}");
    defer view.deinit(alloc);
    try std.testing.expect(readsOnly(view));
    try std.testing.expect(!isIrreversible(view));

    const init = try expectDecodeInput("{\"op\":\"init\",\"items\":[\"Scaffold crate\"]}");
    defer init.deinit(alloc);
    try std.testing.expect(!readsOnly(init));

    const omitted = try expectDecodeInput("{\"items\":[\"Scaffold crate\"]}");
    defer omitted.deinit(alloc);
    try std.testing.expect(!readsOnly(omitted));
    try std.testing.expect(!isIrreversible(omitted));
}

test "todo validation defers every per-operation check to the state machine" {
    const alloc = std.testing.allocator;
    const input = try expectDecodeInput("{\"op\":\"done\"}");
    defer input.deinit(alloc);
    try std.testing.expect((try validate(dispatchContext(alloc, null), input)) == null);
}

test "todo call runs a full session list lifecycle" {
    const alloc = std.testing.allocator;
    var session: todo_state.Session = .{};
    defer session.deinit(alloc, std.testing.io);

    try expectSuccessText(alloc, &session,
        \\{"op":"init","list":[{"phase":"Foundation","items":["Scaffold crate","Wire workspace"]},
        \\{"phase":"Verification","items":["Run tests"]}]}
    ,
        \\Remaining items (3):
        \\  - Scaffold crate [in_progress] (Foundation)
        \\  - Wire workspace [pending] (Foundation)
        \\  - Run tests [pending] (Verification)
        \\Overall: 0/3 done, 3 open.
        \\Active phase 1/2 "Foundation" (0/2).
        \\  Foundation:
        \\    - [ ] Scaffold crate (in progress)
        \\    - [ ] Wire workspace
        \\  Verification:
        \\    - [ ] Run tests
    );
    try expectSuccessText(alloc, &session, "{\"op\":\"append\",\"phase\":\"Verification\",\"items\":[\"Handle retries\"]}",
        \\Remaining items (4):
        \\  - Scaffold crate [in_progress] (Foundation)
        \\  - Wire workspace [pending] (Foundation)
        \\  - Run tests [pending] (Verification)
        \\  - Handle retries [pending] (Verification)
        \\Overall: 0/4 done, 4 open.
        \\Active phase 1/2 "Foundation" (0/2).
        \\  Foundation:
        \\    - [ ] Scaffold crate (in progress)
        \\    - [ ] Wire workspace
        \\  Verification:
        \\    - [ ] Run tests
        \\    - [ ] Handle retries
    );
    try expectSuccessText(alloc, &session, "{\"op\":\"done\",\"phase\":\"Foundation\"}",
        \\Remaining items (2):
        \\  - Run tests [in_progress] (Verification)
        \\  - Handle retries [pending] (Verification)
        \\Overall: 2/4 done, 2 open.
        \\Active phase 2/2 "Verification" (0/2).
        \\  Foundation:
        \\    - [X] Scaffold crate
        \\    - [X] Wire workspace
        \\  Verification:
        \\    - [ ] Run tests (in progress)
        \\    - [ ] Handle retries
    );
    try expectSuccessText(alloc, &session, "{\"op\":\"drop\",\"task\":\"Handle retries\"}",
        \\Remaining items (1):
        \\  - Run tests [in_progress] (Verification)
        \\Overall: 3/4 done, 1 open.
        \\Active phase 2/2 "Verification" (1/2).
        \\  Foundation:
        \\    - [X] Scaffold crate
        \\    - [X] Wire workspace
        \\  Verification:
        \\    - [ ] Run tests (in progress)
        \\    - [ ] Handle retries (dropped)
    );
    try expectSuccessText(alloc, &session, "{\"op\":\"rm\"}", "Todo list cleared.");
    try expectSuccessText(alloc, &session, "{\"op\":\"view\"}", "Todo list is empty.");
}

test "todo call reports a rejected request without changing the list" {
    const alloc = std.testing.allocator;
    var session: todo_state.Session = .{};
    defer session.deinit(alloc, std.testing.io);
    try expectSuccessText(alloc, &session, "{\"op\":\"init\",\"items\":[\"Apply fix\"]}",
        \\Remaining items (1):
        \\  - Apply fix [in_progress] (Tasks)
        \\Overall: 0/1 done, 1 open.
        \\Active phase 1/1 "Tasks" (0/1).
        \\  Tasks:
        \\    - [ ] Apply fix (in progress)
    );
    try expectSuccessText(alloc, &session, "{\"op\":\"append\",\"phase\":\"Tasks\",\"items\":[\"Apply fix\"]}",
        \\Errors: Task "Apply fix" already exists
        \\Remaining items (1):
        \\  - Apply fix [in_progress] (Tasks)
        \\Overall: 0/1 done, 1 open.
        \\Active phase 1/1 "Tasks" (0/1).
        \\  Tasks:
        \\    - [ ] Apply fix (in progress)
    );
    try expectSuccessText(alloc, &session, "{\"op\":\"view\"}",
        \\Remaining items (1):
        \\  - Apply fix [in_progress] (Tasks)
        \\Overall: 0/1 done, 1 open.
        \\Active phase 1/1 "Tasks" (0/1).
        \\  Tasks:
        \\    - [ ] Apply fix (in progress)
    );
}

test "todo call infers an omitted operation only from an unambiguous payload" {
    const alloc = std.testing.allocator;
    var session: todo_state.Session = .{};
    defer session.deinit(alloc, std.testing.io);
    try expectSuccessText(alloc, &session, "{\"items\":[\"Scaffold crate\"]}",
        \\Remaining items (1):
        \\  - Scaffold crate [in_progress] (Tasks)
        \\Overall: 0/1 done, 1 open.
        \\Active phase 1/1 "Tasks" (0/1).
        \\  Tasks:
        \\    - [ ] Scaffold crate (in progress)
    );
    try expectSuccessText(alloc, &session, "{\"phase\":\"Tasks\",\"items\":[\"Wire workspace\"]}",
        \\Remaining items (2):
        \\  - Scaffold crate [in_progress] (Tasks)
        \\  - Wire workspace [pending] (Tasks)
        \\Overall: 0/2 done, 2 open.
        \\Active phase 1/1 "Tasks" (0/2).
        \\  Tasks:
        \\    - [ ] Scaffold crate (in progress)
        \\    - [ ] Wire workspace
    );
    try expectFailureText(alloc, &session, "{\"items\":[\"Log retries\"]}", "todo field \"op\" is required unless list or items names one operation");
    try expectFailureText(alloc, &session, "{\"task\":\"Scaffold crate\"}", "todo field \"op\" is required unless list or items names one operation");
}

test "todo call reports a dispatch context with no session state" {
    const alloc = std.testing.allocator;
    const input = try expectDecodeInput("{\"op\":\"view\"}");
    defer input.deinit(alloc);
    const result = try call(dispatchContext(alloc, null), input);
    const body = switch (result) {
        .failure => |text| text,
        .success, .rich => return error.TestUnexpectedResult,
    };
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "todo requires a live session: no todo state is available",
        body,
    );
}

test "todo list survives the per-call arena that produced the summary" {
    // A real dispatch context hands the tool a per-call arena as its allocator
    // and the session allocator for anything that outlives the call. Owning the
    // list with the arena frees it the moment the call returns, so this drives
    // two calls through separate arenas over one session and reads the list back
    // after the first arena is gone.
    const alloc = std.testing.allocator;
    var session: todo_state.Session = .{};
    defer session.deinit(alloc, std.testing.io);

    var seed_arena = std.heap.ArenaAllocator.init(alloc);
    const seeded = try runCallIn(seed_arena.allocator(), alloc, &session,
        \\{"list":[{"phase":"Implementation","items":["Apply fix"]}]}
    );
    switch (seeded) {
        .success => |text| {
            const owned = try alloc.dupe(u8, text);
            defer alloc.free(owned);
            try std.testing.expect(std.mem.indexOf(u8, owned, "Apply fix") != null);
        },
        .failure, .rich => return error.TestUnexpectedResult,
    }
    seed_arena.deinit();

    var read_arena = std.heap.ArenaAllocator.init(alloc);
    const viewed = try runCallIn(read_arena.allocator(), alloc, &session, "{\"op\":\"view\"}");
    switch (viewed) {
        .success => |text| {
            const owned = try alloc.dupe(u8, text);
            defer alloc.free(owned);
            try std.testing.expect(std.mem.indexOf(u8, owned, "Apply fix") != null);
        },
        .failure, .rich => return error.TestUnexpectedResult,
    }
    read_arena.deinit();
}
