const std = @import("std");
const builtin = @import("builtin");
const shell_resolver = @import("../terminal/shell_resolver.zig");

const c = struct {
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, len: usize) isize;
};

const fallback_shell = "/bin/bash";
const max_command_bytes: usize = 100_000;
const x_ok: c_int = 1;

pub const env_switch = "DI_ZASH";
pub const env_bin = "DI_ZASH_BIN";
pub const env_fallback = "ZASH_BASH_FALLBACK";
pub const fallback_entry = env_fallback ++ "=" ++ fallback_shell;

pub fn enabledValue(value: ?[]const u8) bool {
    const v = value orelse return true;
    if (v.len == 0) return true;
    const off = [_][]const u8{ "0", "off", "false", "no" };
    for (off) |o| if (std.ascii.eqlIgnoreCase(v, o)) return false;
    return true;
}

pub fn eligible(command: []const u8) bool {
    if (command.len == 0 or command.len > max_command_bytes) return false;
    return std.mem.findScalar(u8, command, 0) == null;
}

fn getenv(name: [:0]const u8) ?[]const u8 {
    const p = c.getenv(name.ptr) orelse return null;
    return std.mem.span(p);
}

fn executable(path: [:0]const u8) bool {
    return c.access(path.ptr, x_ok) == 0;
}

/// Path of the zash executable, or null when the integration is off or no
/// zash/bash pair is installed. Written into `buf`.
pub fn locate(buf: []u8) ?[:0]const u8 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    if (!enabledValue(getenv(env_switch))) return null;
    if (c.access(fallback_shell, x_ok) != 0) return null;
    if (getenv(env_bin)) |explicit| {
        if (explicit.len == 0 or explicit.len >= buf.len) return null;
        @memcpy(buf[0..explicit.len], explicit);
        buf[explicit.len] = 0;
        const z = buf[0..explicit.len :0];
        return if (executable(z)) z else null;
    }
    if (builtin.os.tag != .linux) return null;
    var exe: [std.fs.max_path_bytes]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &exe, exe.len);
    if (n <= 0) return null;
    const dir = std.fs.path.dirname(exe[0..@intCast(n)]) orelse return null;
    const name = "zash";
    if (dir.len + 1 + name.len >= buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = '/';
    @memcpy(buf[dir.len + 1 ..][0..name.len], name);
    buf[dir.len + 1 + name.len] = 0;
    const z = buf[0 .. dir.len + 1 + name.len :0];
    return if (executable(z)) z else null;
}

pub fn invocation(path: []const u8, command: []const u8) shell_resolver.Invocation {
    var inv = shell_resolver.Invocation{ .path = path };
    inv.append(path);
    inv.setCommand(command);
    return inv;
}

test "kill switch values" {
    try std.testing.expect(enabledValue(null));
    try std.testing.expect(enabledValue(""));
    try std.testing.expect(enabledValue("1"));
    try std.testing.expect(!enabledValue("0"));
    try std.testing.expect(!enabledValue("off"));
    try std.testing.expect(!enabledValue("False"));
}

test "eligibility bounds the command size and rejects NUL" {
    try std.testing.expect(eligible("echo hi"));
    try std.testing.expect(!eligible(""));
    try std.testing.expect(!eligible("echo \x00"));
    const big = try std.testing.allocator.alloc(u8, max_command_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try std.testing.expect(!eligible(big));
}

test "invocation is zash -c command" {
    const inv = invocation("/opt/zash", "echo hi | tr a-z A-Z");
    const argv = inv.argv();
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("/opt/zash", argv[0]);
    try std.testing.expectEqualStrings("-c", argv[1]);
    try std.testing.expectEqualStrings("echo hi | tr a-z A-Z", argv[2]);
}

test "locate honors the kill switch and explicit path" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const set = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    defer {
        _ = set.unsetenv(env_switch);
        _ = set.unsetenv(env_bin);
    }
    _ = set.setenv(env_bin, "/bin/sh", 1);
    _ = set.unsetenv(env_switch);
    if (c.access(fallback_shell, x_ok) == 0) {
        try std.testing.expectEqualStrings("/bin/sh", locate(&buf).?);
    }
    _ = set.setenv(env_switch, "0", 1);
    try std.testing.expect(locate(&buf) == null);
    _ = set.setenv(env_switch, "1", 1);
    _ = set.setenv(env_bin, "/nonexistent/zash", 1);
    try std.testing.expect(locate(&buf) == null);
}
