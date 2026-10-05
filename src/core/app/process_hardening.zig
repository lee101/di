const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;
const pr_set_dumpable = 4;
const pr_get_dumpable = 3;

pub fn apply(allow_debug_env: ?[]const u8) void {
    if (comptime builtin.os.tag != .linux) return;
    if (allow_debug_env) |value| {
        if (std.mem.eql(u8, value, "1")) return;
    }
    _ = linux.prctl(pr_set_dumpable, 0, 0, 0, 0);
    std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
}

test "apply makes the process non-dumpable and clears the core limit" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const saved_limit = try std.posix.getrlimit(.CORE);
    const saved_dumpable = linux.prctl(pr_get_dumpable, 0, 0, 0, 0);
    defer {
        _ = linux.prctl(pr_set_dumpable, saved_dumpable, 0, 0, 0);
        std.posix.setrlimit(.CORE, saved_limit) catch {};
    }

    _ = linux.prctl(pr_set_dumpable, 1, 0, 0, 0);
    apply("1");
    try std.testing.expectEqual(@as(usize, 1), linux.prctl(pr_get_dumpable, 0, 0, 0, 0));

    apply(null);
    try std.testing.expectEqual(@as(usize, 0), linux.prctl(pr_get_dumpable, 0, 0, 0, 0));
    const limit = try std.posix.getrlimit(.CORE);
    try std.testing.expectEqual(@as(@TypeOf(limit.cur), 0), limit.cur);
    try std.testing.expectEqual(@as(@TypeOf(limit.max), 0), limit.max);
}
