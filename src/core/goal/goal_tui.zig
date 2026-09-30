const std = @import("std");
const goal = @import("goal.zig");
const io_mod = @import("../shared/io.zig");

pub const State = struct {
    driving: bool = false,
    turn_done: bool = false,
    tokens_mark: u64 = 0,
    started_ms: i64 = 0,
    reply_len: usize = 0,
    reply_tail: [4096]u8 = undefined,

    pub fn setReply(self: *State, text: []const u8) void {
        const tail = text[text.len -| self.reply_tail.len..];
        @memcpy(self.reply_tail[0..tail.len], tail);
        self.reply_len = tail.len;
    }

    pub fn reply(self: *const State) []const u8 {
        return self.reply_tail[0..self.reply_len];
    }
};

fn notice(comptime App: type, app: *App, tone: enum { neutral, err }, body: []const u8) void {
    app.writeDomainNotice(.{
        .topic = "goal",
        .tone = if (tone == .err) .@"error" else .neutral,
        .body = body,
    }, true) catch {};
}

fn totalTokens(comptime App: type, app: *App) u64 {
    const t = app.session.usage.sessionTotals();
    return t.input_tokens +| t.output_tokens;
}

fn paths(comptime App: type, app: *App, dir: *[]u8, path: *[]u8) !void {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    dir.* = try goal.goalsDir(app.alloc, home);
    errdefer app.alloc.free(dir.*);
    path.* = try goal.goalPath(app.alloc, dir.*, app.workspace_root);
}

pub fn handle(comptime App: type, app: *App, rest: []const u8) !void {
    if (comptime !@hasField(App, "goal_tui") or !@hasField(App, "workspace_root")) {
        notice(App, app, .err, "Goal mode is unavailable in this runtime.");
        return;
    }
    var dir: []u8 = undefined;
    var path: []u8 = undefined;
    paths(App, app, &dir, &path) catch {
        notice(App, app, .err, "Goal store unavailable: HOME is not set.");
        return;
    };
    defer app.alloc.free(dir);
    defer app.alloc.free(path);

    const cmd = goal.parseCommand(rest);
    switch (cmd) {
        .invalid => |why| {
            const msg = try std.fmt.allocPrint(app.alloc, "{s}. Usage: {s}", .{ why, goal.usage });
            defer app.alloc.free(msg);
            notice(App, app, .err, msg);
        },
        .show => {
            var cur = (try goal.load(app.alloc, path)) orelse {
                notice(App, app, .neutral, "No goal for this workspace. Set one with /goal OBJECTIVE [--tokens N] [--turns N] [--time D].");
                return;
            };
            defer cur.deinit();
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try goal.writeSummary(&out.writer, cur.goal);
            if (cur.goal.status == .active) try out.writer.print("driving: {s}\n", .{if (app.goal_tui.driving) "yes" else "no (use /goal resume)"});
            notice(App, app, .neutral, std.mem.trimEnd(u8, out.written(), "\n"));
        },
        .set => |s| {
            var owned = try goal.Owned.init(app.alloc, s.objective, s.budget, io_mod.milliTimestamp());
            defer owned.deinit();
            try goal.save(app.alloc, dir, path, &owned.goal);
            try start(App, app, &owned.goal, "goal set");
        },
        .resume_ => {
            var cur = (try goal.load(app.alloc, path)) orelse {
                notice(App, app, .err, "No goal to resume.");
                return;
            };
            defer cur.deinit();
            if (cur.goal.status == .complete) {
                notice(App, app, .neutral, "Goal already complete. Set a new one with /goal OBJECTIVE.");
                return;
            }
            cur.resume_();
            if (cur.goal.budgetExhausted()) {
                notice(App, app, .err, "Goal budget exhausted. Raise it with /goal budget --tokens N --turns N --time D.");
                return;
            }
            try goal.save(app.alloc, dir, path, &cur.goal);
            try start(App, app, &cur.goal, "goal resumed");
        },
        .pause => {
            var cur = (try goal.load(app.alloc, path)) orelse {
                notice(App, app, .err, "No goal to pause.");
                return;
            };
            defer cur.deinit();
            if (cur.goal.status == .active) cur.goal.status = .paused;
            try goal.save(app.alloc, dir, path, &cur.goal);
            app.goal_tui.driving = false;
            notice(App, app, .neutral, "goal paused");
        },
        .clear => {
            try goal.remove(path);
            app.goal_tui.driving = false;
            notice(App, app, .neutral, "goal cleared");
        },
        .budget => |b| {
            var cur = (try goal.load(app.alloc, path)) orelse {
                notice(App, app, .err, "No goal to update.");
                return;
            };
            defer cur.deinit();
            if (b.tokens) |t| cur.goal.budget.tokens = t;
            if (b.turns) |t| cur.goal.budget.turns = t;
            if (b.time_s) |t| cur.goal.budget.time_s = t;
            try goal.save(app.alloc, dir, path, &cur.goal);
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try goal.writeSummary(&out.writer, cur.goal);
            notice(App, app, .neutral, std.mem.trimEnd(u8, out.written(), "\n"));
        },
    }
}

fn start(comptime App: type, app: *App, g: *const goal.Goal, label: []const u8) !void {
    app.goal_tui.driving = true;
    app.goal_tui.tokens_mark = totalTokens(App, app);
    app.goal_tui.started_ms = io_mod.milliTimestamp();
    const first = try goal.firstPrompt(app.alloc, g.*);
    defer app.alloc.free(first);
    notice(App, app, .neutral, label);
    _ = try app.enqueuePrompt(first);
}

pub fn turnEnded(comptime App: type, app: *App) void {
    if (comptime !@hasField(App, "goal_tui") or !@hasField(App, "workspace_root")) return;
    if (!app.goal_tui.driving) return;
    turnEndedInner(App, app) catch {
        app.goal_tui.driving = false;
    };
}

fn turnEndedInner(comptime App: type, app: *App) !void {
    var dir: []u8 = undefined;
    var path: []u8 = undefined;
    try paths(App, app, &dir, &path);
    defer app.alloc.free(dir);
    defer app.alloc.free(path);
    var cur = (try goal.load(app.alloc, path)) orelse {
        app.goal_tui.driving = false;
        return;
    };
    defer cur.deinit();
    if (cur.goal.status != .active) {
        app.goal_tui.driving = false;
        return;
    }
    const now = io_mod.milliTimestamp();
    const total = totalTokens(App, app);
    const verdict = try goal.recordTurn(&cur, .{
        .output = app.goal_tui.reply(),
        .tokens = total -| app.goal_tui.tokens_mark,
        .elapsed_s = @intCast(@divTrunc(@max(0, now - app.goal_tui.started_ms) + 500, 1000)),
        .tool_calls = 1,
    });
    app.goal_tui.tokens_mark = total;
    app.goal_tui.started_ms = now;
    try goal.save(app.alloc, dir, path, &cur.goal);
    var line: std.Io.Writer.Allocating = .init(app.alloc);
    defer line.deinit();
    try goal.writeStatusLine(&line.writer, cur.goal, verdict);
    notice(App, app, .neutral, std.mem.trimEnd(u8, line.written(), "\n"));
    if (verdict != .keep_going) {
        app.goal_tui.driving = false;
        return;
    }
    const next = try goal.nextPrompt(app.alloc, cur.goal);
    defer app.alloc.free(next);
    _ = try app.enqueuePrompt(next);
}
