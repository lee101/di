const std = @import("std");
const goal = @import("goal.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

pub fn sessionExists(home: []const u8, id: []const u8) bool {
    if (id.len == 0 or std.mem.indexOfAny(u8, id, "/\\") != null) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}/sessions/{s}/events.jsonl", .{ home, profile_paths.root_dir_name, id }) catch return false;
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

pub const Begin = union(enum) {
    ready: Run,
    exit: u8,
};

pub const Run = struct {
    alloc: std.mem.Allocator,
    owned: goal.Owned,
    dir: []u8,
    path: []u8,
    turn_started_ms: i64 = 0,
    resumed: bool = false,

    pub fn deinit(self: *Run) void {
        self.owned.deinit();
        self.alloc.free(self.dir);
        self.alloc.free(self.path);
    }

    pub fn begin(
        alloc: std.mem.Allocator,
        home: []const u8,
        workspace: []const u8,
        objective: []const u8,
        budget: goal.Budget,
        msg: *std.Io.Writer,
    ) !Begin {
        const dir = try goal.goalsDir(alloc, home);
        errdefer alloc.free(dir);
        const path = try goal.goalPath(alloc, dir, workspace);
        errdefer alloc.free(path);
        const now = io_mod.milliTimestamp();
        const wanted = std.mem.trim(u8, objective, " \t\r\n");
        var stored = try goal.load(alloc, path);
        if (stored) |*s| {
            const same = wanted.len == 0 or std.mem.eql(u8, wanted, s.goal.objective);
            if (same and s.goal.status == .complete) {
                s.deinit();
                try msg.writeAll("di ask: saved goal is already complete; pass a new objective or run /goal clear\n");
                alloc.free(dir);
                alloc.free(path);
                return .{ .exit = 0 };
            }
            if (same) {
                if (budget.tokens) |t| s.goal.budget.tokens = t;
                if (budget.turns) |t| s.goal.budget.turns = t;
                if (budget.time_s) |t| s.goal.budget.time_s = t;
                s.resume_();
                if (s.goal.budgetExhausted()) {
                    s.deinit();
                    try msg.writeAll("di ask: goal budget exhausted; raise it with --goal-tokens, --goal-turns or --goal-time\n");
                    alloc.free(dir);
                    alloc.free(path);
                    return .{ .exit = goal.Status.budget_limited.exitCode() };
                }
                return .{ .ready = .{ .alloc = alloc, .owned = s.*, .dir = dir, .path = path, .resumed = true } };
            }
            s.deinit();
        }
        if (wanted.len == 0) {
            try msg.writeAll("di ask: no saved goal for this workspace; pass an objective\n");
            alloc.free(dir);
            alloc.free(path);
            return .{ .exit = 1 };
        }
        var owned = try goal.Owned.init(alloc, wanted, budget, now);
        errdefer owned.deinit();
        return .{ .ready = .{ .alloc = alloc, .owned = owned, .dir = dir, .path = path } };
    }

    pub fn prompt(self: *Run, first: bool) ![]u8 {
        if (first) return goal.firstPrompt(self.alloc, self.owned.goal);
        return goal.nextPrompt(self.alloc, self.owned.goal);
    }

    pub fn persist(self: *Run) !void {
        try goal.save(self.alloc, self.dir, self.path, &self.owned.goal);
    }

    pub fn turnStarted(self: *Run) void {
        self.turn_started_ms = io_mod.milliTimestamp();
    }

    pub fn finishTurn(
        self: *Run,
        output: []const u8,
        tokens: u64,
        tool_calls: usize,
        session_id: []const u8,
        w: *std.Io.Writer,
    ) !goal.Verdict {
        const elapsed_ms = @max(0, io_mod.milliTimestamp() - self.turn_started_ms);
        const verdict = try goal.recordTurn(&self.owned, .{
            .output = output,
            .tokens = tokens,
            .elapsed_s = @intCast(@divTrunc(elapsed_ms + 500, 1000)),
            .tool_calls = tool_calls,
        });
        try self.owned.setSession(session_id);
        if (try goal.load(self.alloc, self.path)) |*cur| {
            var c = cur.*;
            defer c.deinit();
            if (c.goal.status == .paused and self.owned.goal.status == .active) self.owned.goal.status = .paused;
            try self.persist();
        }
        try goal.writeStatusLine(w, self.owned.goal, verdict);
        return verdict;
    }

    pub fn externallyStopped(self: *Run, w: *std.Io.Writer) !bool {
        var cur = (try goal.load(self.alloc, self.path)) orelse {
            try w.writeAll("[goal] cleared externally; stopping\n");
            return true;
        };
        defer cur.deinit();
        if (cur.goal.status == .active) return false;
        try w.print("[goal] {s} externally; stopping\n", .{cur.goal.status.label()});
        return true;
    }
};

const testing = std.testing;

fn testDirs(tmp: *std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, ".");
}

test "begin creates, persists, and resumes across runs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testDirs(&tmp);
    defer testing.allocator.free(home);
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();

    var first = (try Run.begin(testing.allocator, home, "/ws", "build thing", .{ .turns = 5 }, &sink.writer)).ready;
    defer first.deinit();
    try first.persist();
    first.turnStarted();
    const v = try first.finishTurn("GOAL: continue\nPROGRESS: started", 42, 2, "sess1", &sink.writer);
    try testing.expectEqual(goal.Verdict.keep_going, v);

    var second = (try Run.begin(testing.allocator, home, "/ws", "", .{}, &sink.writer)).ready;
    defer second.deinit();
    try testing.expect(second.resumed);
    try testing.expectEqual(@as(u32, 1), second.owned.goal.turns);
    try testing.expectEqualStrings("sess1", second.owned.goal.session);
    try testing.expectEqual(@as(?u32, 5), second.owned.goal.budget.turns);
}

test "begin replaces a different objective and refuses empty without store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testDirs(&tmp);
    defer testing.allocator.free(home);
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    const none = try Run.begin(testing.allocator, home, "/ws", "", .{}, &sink.writer);
    try testing.expectEqual(@as(u8, 1), none.exit);
    var a = (try Run.begin(testing.allocator, home, "/ws", "one", .{}, &sink.writer)).ready;
    defer a.deinit();
    try a.persist();
    var b = (try Run.begin(testing.allocator, home, "/ws", "two", .{}, &sink.writer)).ready;
    defer b.deinit();
    try testing.expect(!b.resumed);
    try testing.expectEqualStrings("two", b.owned.goal.objective);
}

test "budget exhausted goal needs a raised budget and external pause is detected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testDirs(&tmp);
    defer testing.allocator.free(home);
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    var a = (try Run.begin(testing.allocator, home, "/ws", "one", .{ .turns = 1 }, &sink.writer)).ready;
    defer a.deinit();
    try a.persist();
    a.turnStarted();
    try testing.expectEqual(goal.Verdict.budget_limited, try a.finishTurn("GOAL: continue\nPROGRESS: x", 1, 1, "s", &sink.writer));
    const refused = try Run.begin(testing.allocator, home, "/ws", "", .{}, &sink.writer);
    try testing.expectEqual(@as(u8, 4), refused.exit);
    var raised = (try Run.begin(testing.allocator, home, "/ws", "", .{ .turns = 3 }, &sink.writer)).ready;
    defer raised.deinit();
    try raised.persist();
    try testing.expect(!try raised.externallyStopped(&sink.writer));
    var other = (try goal.load(testing.allocator, raised.path)).?;
    defer other.deinit();
    other.goal.status = .paused;
    try goal.save(testing.allocator, raised.dir, raised.path, &other.goal);
    try testing.expect(try raised.externallyStopped(&sink.writer));
}
