//! Native system URL opener behind the host.UrlOpener contract. Opens a URL
//! in the user's default browser via the platform launcher; shared by
//! authentication and user-consented URL flows.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("host.zig");
const io_mod = @import("../shared/io.zig");
const native = @import("native.zig");

const Allocator = std.mem.Allocator;

pub const native_opener = host.UrlOpener{
    .open_fn = openUrlForHost,
};

fn openUrlForHost(_: ?*anyopaque, alloc: Allocator, url: []const u8) host.UrlOpenError!bool {
    return openUrl(alloc, url);
}

fn openUrl(alloc: Allocator, url: []const u8) Allocator.Error!bool {
    return launchUrl(alloc, url, builtin.os.tag, .{}) == .opened;
}

const LaunchResult = struct {
    /// null when the opener was handed off and is still running at the
    /// launch deadline.
    term: ?std.process.Child.Term,
};

const LaunchFn = *const fn (*anyopaque, Allocator, []const []const u8) anyerror!LaunchResult;

const Launcher = struct {
    ctx: *anyopaque = undefined,
    launch: LaunchFn = launchActual,
};

const LaunchOutcome = enum {
    opened,
    failed,
    unsupported,
};

const opener_wait_bound_ms = 250;
const opener_reap_interval_ms = 10;

var detached_opener_pid: ?std.posix.pid_t = null;

fn reapDetachedOpener() void {
    const pid = detached_opener_pid orelse return;
    var status: c_int = undefined;
    if (std.c.waitpid(pid, &status, std.c.W.NOHANG) != 0) detached_opener_pid = null;
}

fn launchActual(_: *anyopaque, _: Allocator, argv: []const []const u8) anyerror!LaunchResult {
    reapDetachedOpener();
    const io = io_mod.getIo();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(opener_wait_bound_ms),
    });
    while (true) {
        if (try native.try_reap_child_process(&child)) |term| return .{ .term = term };
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) {
            detached_opener_pid = child.id.?;
            return .{ .term = null };
        }
        try std.Io.sleep(io, .fromMilliseconds(opener_reap_interval_ms), .awake);
    }
}

fn launchUrl(
    alloc: Allocator,
    url: []const u8,
    os_tag: std.Target.Os.Tag,
    launcher: Launcher,
) LaunchOutcome {
    var macos_argv = [_][]const u8{ "open", url };
    var linux_argv = [_][]const u8{ "xdg-open", url };
    const argv: []const []const u8 = switch (os_tag) {
        .macos => &macos_argv,
        .linux => &linux_argv,
        else => return .unsupported,
    };

    const result = launcher.launch(launcher.ctx, alloc, argv) catch |err| {
        debug_trace.logf("core", "url opener launcher failed err={s}", .{@errorName(err)});
        return .failed;
    };
    const term = result.term orelse return .opened;
    switch (term) {
        .exited => |code| if (code == 0) return .opened,
        else => {},
    }

    logUnsuccessfulTerm(term);
    return .failed;
}

fn logUnsuccessfulTerm(term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| debug_trace.logf("core", "url opener unsuccessful term=exited exit_code={d}", .{code}),
        .signal => |sig| debug_trace.logf("core", "url opener unsuccessful term=signal signal={d}", .{@intFromEnum(sig)}),
        .stopped => |sig| debug_trace.logf("core", "url opener unsuccessful term=stopped signal={d}", .{@intFromEnum(sig)}),
        .unknown => |code| debug_trace.logf("core", "url opener unsuccessful term=unknown status={d}", .{code}),
    }
}

const MockLauncher = struct {
    argv_joined: std.ArrayList(u8) = .empty,
    result: anyerror!LaunchResult = .{ .term = .{ .exited = 0 } },

    fn launch(raw: *anyopaque, alloc: Allocator, argv: []const []const u8) anyerror!LaunchResult {
        const self: *MockLauncher = @ptrCast(@alignCast(raw));
        for (argv, 0..) |arg, i| {
            if (i > 0) try self.argv_joined.append(alloc, ' ');
            try self.argv_joined.appendSlice(alloc, arg);
        }
        return self.result;
    }

    fn launcher(self: *MockLauncher) Launcher {
        return .{ .ctx = self, .launch = launch };
    }

    fn deinit(self: *MockLauncher, alloc: Allocator) void {
        self.argv_joined.deinit(alloc);
    }
};

test "url opener selects the platform launcher argv" {
    const alloc = std.testing.allocator;

    var macos = MockLauncher{};
    defer macos.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchUrl(alloc, "http://localhost:3000", .macos, macos.launcher()));
    try std.testing.expectEqualStrings("open http://localhost:3000", macos.argv_joined.items);

    var linux = MockLauncher{};
    defer linux.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchUrl(alloc, "http://localhost:3000", .linux, linux.launcher()));
    try std.testing.expectEqualStrings("xdg-open http://localhost:3000", linux.argv_joined.items);
}

test "url opener reports unsupported platforms without launching" {
    const alloc = std.testing.allocator;
    var mock = MockLauncher{};
    defer mock.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.unsupported, launchUrl(alloc, "http://x", .windows, mock.launcher()));
    try std.testing.expectEqualStrings("", mock.argv_joined.items);
}

test "url opener treats nonzero exit, bad terms, and launch errors as failed" {
    const alloc = std.testing.allocator;

    var nonzero = MockLauncher{ .result = .{ .term = .{ .exited = 3 } } };
    defer nonzero.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchUrl(alloc, "http://x", .macos, nonzero.launcher()));

    var signaled = MockLauncher{ .result = .{ .term = .{ .signal = @enumFromInt(2) } } };
    defer signaled.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchUrl(alloc, "http://x", .macos, signaled.launcher()));

    var erroring = MockLauncher{ .result = error.SpawnFailed };
    defer erroring.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchUrl(alloc, "http://x", .linux, erroring.launcher()));
}

test "url opener treats an opener still running at the deadline as opened" {
    const alloc = std.testing.allocator;
    var mock = MockLauncher{ .result = .{ .term = null } };
    defer mock.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchUrl(alloc, "http://x", .linux, mock.launcher()));
    try std.testing.expectEqualStrings("xdg-open http://x", mock.argv_joined.items);
}

test "url opener detaches a hanging launcher without blocking" {
    const alloc = std.testing.allocator;
    const argv = [_][]const u8{ "/bin/sh", "-c", "sleep 30" };
    const started_ms = io_mod.milliTimestamp();
    const result = try launchActual(undefined, alloc, &argv);
    const elapsed_ms = io_mod.milliTimestamp() - started_ms;

    try std.testing.expect(result.term == null);
    try std.testing.expect(elapsed_ms < 5000);
    const pid = detached_opener_pid orelse return error.TestUnexpectedResult;
    detached_opener_pid = null;
    std.posix.kill(pid, .KILL) catch {};
    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
}

test "url opener real launcher maps fast exit terms" {
    const alloc = std.testing.allocator;
    const ok_argv = [_][]const u8{ "/bin/sh", "-c", "exit 0" };
    const ok = try launchActual(undefined, alloc, &ok_argv);
    try std.testing.expectEqual(@as(?std.process.Child.Term, .{ .exited = 0 }), ok.term);

    const bad_argv = [_][]const u8{ "/bin/sh", "-c", "exit 3" };
    const bad = try launchActual(undefined, alloc, &bad_argv);
    try std.testing.expectEqual(@as(?std.process.Child.Term, .{ .exited = 3 }), bad.term);
    try std.testing.expect(detached_opener_pid == null);
}

test "url opener reaps a detached opener once it exits" {
    const io = io_mod.getIo();
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    detached_opener_pid = child.id.?;
    child.id = null;

    var attempts: usize = 0;
    while (detached_opener_pid != null and attempts < 500) : (attempts += 1) {
        reapDetachedOpener();
        if (detached_opener_pid != null) try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(detached_opener_pid == null);
}
