//! Warm user-profile shell for captured commands.
//!
//! The user profile (`bash --login`) can cost from 15ms to several seconds
//! per command. The login result is captured once (aliases, functions, shopt
//! and the exported-environment delta) and cached on disk under a key made of
//! the shell, the inherited environment and the startup files' mtimes. Later
//! commands run `bash --noprofile` with the delta applied via `env` and the
//! script loaded through BASH_ENV, keeping the user's PATH and aliases.
//! Disable with FX_SHELL_SNAPSHOT=0. Any failure falls back to the login shell.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const format_tag = "fx-shell-snapshot-v1";
const ttl_ms: i64 = 12 * 3600 * 1000;
const max_script_bytes: usize = 1024 * 1024;
const max_env_arg_bytes: usize = 96 * 1024;
const begin_marker = "\n@@FX_SNAPSHOT_BEGIN@@\n";
const env_marker = "\n@@FX_SNAPSHOT_ENV@@\n";
const generator_script =
    "printf '\\n@@FX_SNAPSHOT_BEGIN@@\\n'\n" ++
    "shopt -p 2>/dev/null | grep -v login_shell\n" ++
    "alias -p 2>/dev/null\n" ++
    "declare -f 2>/dev/null\n" ++
    "printf '\\n@@FX_SNAPSHOT_ENV@@\\n'\n" ++
    "env -0\n";

const key_env_names = [_][]const u8{ "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "XDG_CONFIG_HOME" };
const path_rel_tag = "@PATH";

const volatile_names = [_][]const u8{ "PWD", "OLDPWD", "SHLVL", "_", "BASH_ENV", "COLUMNS", "LINES", "SHELLOPTS", "BASHOPTS", "PPID" };

const profile_files = [_][]const u8{
    "/etc/profile",
    "/etc/bash.bashrc",
    "/etc/bashrc",
    "~/.bash_profile",
    "~/.bash_login",
    "~/.profile",
    "~/.bashrc",
};

pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    /// Argv prefix: env, -u/assignments, BASH_ENV, shell, options. Append the command.
    prefix: []const []const u8,
    path_prefix: []const u8 = "",
    path_suffix: []const u8 = "",
    relative_path: bool = false,

    pub fn deinit(self: *Resolved) void {
        self.arena.deinit();
    }

    /// `current_path` is the caller's PATH; the profile's PATH edits are applied around it.
    pub fn argvWith(self: Resolved, alloc: Allocator, current_path: ?[]const u8, command: []const u8) ![]const []const u8 {
        const extra: usize = if (self.relative_path) 1 else 0;
        const out = try alloc.alloc([]const u8, self.prefix.len + 1 + extra);
        // prefix[0] is env; assignments follow, so PATH can go right after it.
        out[0] = self.prefix[0];
        var at: usize = 1;
        if (self.relative_path) {
            const cur = current_path orelse "";
            const joined = try std.mem.concat(alloc, u8, &.{
                if (self.path_prefix.len > 0 and std.mem.startsWith(u8, cur, self.path_prefix)) "" else self.path_prefix,
                cur,
                if (self.path_suffix.len > 0 and std.mem.endsWith(u8, cur, self.path_suffix)) "" else self.path_suffix,
            });
            out[at] = try std.fmt.allocPrint(alloc, "PATH={s}", .{joined});
            at += 1;
        }
        @memcpy(out[at .. at + self.prefix.len - 1], self.prefix[1..]);
        out[out.len - 1] = command;
        return out;
    }
};

pub const Options = struct {
    shell_path: []const u8,
    home: []const u8,
    /// Cache directory; created on demand.
    cache_dir: []const u8,
    env: *const std.process.Environ.Map,
    now_ms: i64 = 0,
    generate_timeout_s: i64 = 60,
};

fn isVolatile(name: []const u8) bool {
    for (volatile_names) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}

fn computeKey(alloc: Allocator, opts: Options) ![32]u8 {
    var h = Sha256.init(.{});
    h.update(format_tag);
    h.update(opts.shell_path);
    var uid_buf: [16]u8 = undefined;
    const uid = if (comptime builtin.link_libc) std.c.getuid() else 0;
    h.update(std.fmt.bufPrint(&uid_buf, "{d}", .{uid}) catch "");
    for (profile_files) |entry| {
        const path = if (entry[0] == '~')
            try std.fs.path.join(alloc, &.{ opts.home, entry[2..] })
        else
            try alloc.dupe(u8, entry);
        defer alloc.free(path);
        h.update(path);
        if (std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{})) |st| {
            var b: [48]u8 = undefined;
            h.update(std.fmt.bufPrint(&b, ":{d}:{d}", .{ st.mtime.nanoseconds, st.size }) catch "");
        } else |_| h.update(":absent");
    }
    for (key_env_names) |name| {
        h.update("\x00");
        h.update(name);
        h.update("=");
        h.update(opts.env.get(name) orelse "");
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return hex[0..32].*;
}

/// Splits the generator output into the sourceable script and the env delta
/// relative to `current`. Returns null when markers are missing or limits are exceeded.
fn assemble(alloc: Allocator, raw: []const u8, current: *const std.process.Environ.Map, script_out: *[]u8, delta_out: *[][]const u8) !bool {
    const begin = std.mem.indexOf(u8, raw, begin_marker) orelse return false;
    const body_start = begin + begin_marker.len;
    const env_at = std.mem.indexOfPos(u8, raw, body_start, env_marker) orelse return false;
    const body = raw[body_start..env_at];
    const env_bytes = raw[env_at + env_marker.len ..];
    if (body.len > max_script_bytes) return false;

    var script: std.Io.Writer.Allocating = .init(alloc);
    errdefer script.deinit();
    try script.writer.writeAll("# " ++ format_tag ++ "\n{\nunset BASH_ENV\n");
    try script.writer.writeAll(body);
    try script.writer.writeAll("\n} 2>/dev/null\n");

    var delta: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (delta.items) |s| alloc.free(s);
        delta.deinit(alloc);
    }
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    var total: usize = 0;
    var parts = std.mem.splitScalar(u8, env_bytes, 0);
    while (parts.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const name = entry[0..eq];
        if (name.len == 0 or isVolatile(name)) continue;
        try seen.put(name, {});
        const value = entry[eq + 1 ..];
        if (current.get(name)) |cur| {
            if (std.mem.eql(u8, cur, value)) continue;
            if (std.mem.eql(u8, name, "PATH") and cur.len > 0) {
                if (std.mem.indexOf(u8, value, cur)) |at| {
                    total += value.len + 8;
                    try delta.append(alloc, try std.fmt.allocPrint(alloc, path_rel_tag ++ "\x00{s}\x00{s}", .{ value[0..at], value[at + cur.len ..] }));
                    continue;
                }
            }
        }
        total += entry.len + 1;
        try delta.append(alloc, try alloc.dupe(u8, entry));
    }
    var cit = current.iterator();
    while (cit.next()) |e| {
        const name = e.key_ptr.*;
        if (isVolatile(name) or seen.contains(name)) continue;
        total += name.len + 4;
        try delta.append(alloc, try std.fmt.allocPrint(alloc, "-u\x00{s}", .{name}));
    }
    if (total > max_env_arg_bytes) {
        for (delta.items) |s| alloc.free(s);
        delta.deinit(alloc);
        script.deinit();
        return false;
    }
    script_out.* = try script.toOwnedSlice();
    delta_out.* = try delta.toOwnedSlice(alloc);
    return true;
}

fn cachePaths(alloc: Allocator, dir: []const u8, key: [32]u8) !struct { script: []u8, env: []u8 } {
    const script = try std.fmt.allocPrint(alloc, "{s}/{s}.sh", .{ dir, key });
    errdefer alloc.free(script);
    const env = try std.fmt.allocPrint(alloc, "{s}/{s}.env", .{ dir, key });
    return .{ .script = script, .env = env };
}

fn readSmall(alloc: Allocator, path: []const u8, max: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max);
}

fn buildPrefix(backing: Allocator, opts: Options, script_path: []const u8, env_blob: []const u8) !Resolved {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var prefix: std.ArrayList([]const u8) = .empty;
    try prefix.append(alloc, "/usr/bin/env");
    var path_prefix: []const u8 = "";
    var path_suffix: []const u8 = "";
    var relative_path = false;
    var parts = std.mem.splitScalar(u8, env_blob, 0);
    while (parts.next()) |first| {
        if (first.len == 0) continue;
        if (std.mem.eql(u8, first, path_rel_tag)) {
            path_prefix = try alloc.dupe(u8, parts.next() orelse "");
            path_suffix = try alloc.dupe(u8, parts.next() orelse "");
            relative_path = true;
        } else if (std.mem.eql(u8, first, "-u")) {
            const name = parts.next() orelse break;
            try prefix.append(alloc, "-u");
            try prefix.append(alloc, try alloc.dupe(u8, name));
        } else try prefix.append(alloc, try alloc.dupe(u8, first));
    }
    try prefix.append(alloc, try std.fmt.allocPrint(alloc, "BASH_ENV={s}", .{script_path}));
    try prefix.append(alloc, try alloc.dupe(u8, opts.shell_path));
    try prefix.append(alloc, "--noprofile");
    try prefix.append(alloc, "-O");
    try prefix.append(alloc, "expand_aliases");
    try prefix.append(alloc, "-c");
    return .{
        .arena = arena,
        .prefix = try prefix.toOwnedSlice(alloc),
        .path_prefix = path_prefix,
        .path_suffix = path_suffix,
        .relative_path = relative_path,
    };
}

fn encodeEnvBlob(alloc: Allocator, delta: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (delta) |entry| {
        try out.writer.writeAll(entry);
        try out.writer.writeByte(0);
    }
    return out.toOwnedSlice();
}

/// Loads a fresh cached snapshot or generates one. `alloc` owns the result.
pub fn resolve(alloc: Allocator, opts: Options) !Resolved {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const now_ms = if (opts.now_ms != 0) opts.now_ms else io_mod.milliTimestamp();
    const key = try computeKey(arena, opts);
    const paths = try cachePaths(arena, opts.cache_dir, key);

    if (readSmall(arena, paths.env, max_env_arg_bytes + 64)) |env_blob| {
        if (std.Io.Dir.cwd().statFile(io_mod.getIo(), paths.script, .{})) |st| {
            const age_ms = now_ms - @as(i64, @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms)));
            if (age_ms >= 0 and age_ms < ttl_ms) {
                return buildPrefix(alloc, opts, paths.script, env_blob);
            }
        } else |_| {}
    } else |_| {}

    const result = try std.process.run(arena, io_mod.getIo(), .{
        .argv = &.{ opts.shell_path, "--login", "-O", "expand_aliases", "-c", generator_script },
        .environ_map = opts.env,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = opts.generate_timeout_s * std.time.ns_per_s },
            .clock = .awake,
        } },
    });
    if (result.term != .exited or result.term.exited != 0) return error.SnapshotGenerationFailed;
    var script: []u8 = undefined;
    var delta: [][]const u8 = undefined;
    if (!try assemble(arena, result.stdout, opts.env, &script, &delta)) return error.SnapshotRejected;
    const env_blob = try encodeEnvBlob(arena, delta);
    try io_mod.makeDirRecursive(opts.cache_dir);
    try io_mod.writeFileAtomic(arena, paths.env, env_blob);
    try io_mod.writeFileAtomic(arena, paths.script, script);
    return buildPrefix(alloc, opts, paths.script, env_blob);
}

var mutex: std.Io.Mutex = .init;
var state: enum { unresolved, ready, failed } = .unresolved;
var resolved: Resolved = undefined;

/// Process-wide entry used by the command runner. Returns null when the
/// warm path is disabled or unavailable (callers use the login shell).
pub fn warmArgv(alloc: Allocator, shell_path: []const u8, command: []const u8) ?[]const []const u8 {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return null;
    if (!std.mem.eql(u8, std.fs.path.basename(shell_path), "bash")) return null;
    if (io_mod.getenv("FX_SHELL_SNAPSHOT")) |v| if (std.mem.eql(u8, v, "0")) return null;
    mutex.lockUncancelable(io_mod.getIo());
    defer mutex.unlock(io_mod.getIo());
    switch (state) {
        .failed => return null,
        .ready => {},
        .unresolved => {
            state = .failed;
            const home = io_mod.getenv("HOME") orelse return null;
            std.Io.Dir.accessAbsolute(io_mod.getIo(), "/usr/bin/env", .{}) catch return null;
            var env = io_mod.cloneEnvironMap(std.heap.page_allocator) catch return null;
            defer env.deinit();
            const fx_dir = profile_paths.rootDir(std.heap.page_allocator, home) catch return null;
            defer std.heap.page_allocator.free(fx_dir);
            const cache_dir = std.fmt.allocPrint(std.heap.page_allocator, "{s}/cache/shell-snapshot", .{fx_dir}) catch return null;
            defer std.heap.page_allocator.free(cache_dir);
            const started = io_mod.milliTimestamp();
            resolved = resolve(std.heap.page_allocator, .{
                .shell_path = shell_path,
                .home = home,
                .cache_dir = cache_dir,
                .env = &env,
            }) catch |err| {
                debug_trace.logf("core", "shell snapshot unavailable err={s}", .{@errorName(err)});
                return null;
            };
            debug_trace.logf("core", "shell snapshot ready in {d}ms", .{io_mod.milliTimestamp() - started});
            state = .ready;
        },
    }
    return resolved.argvWith(alloc, io_mod.getenv("PATH"), command) catch null;
}

const testing = std.testing;

fn testEnv(alloc: Allocator, home: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(alloc);
    errdefer env.deinit();
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("USER", "fxtest");
    try env.put("LANG", "C");
    return env;
}

test "assemble computes exported delta and unset list" {
    const alloc = testing.allocator;
    var current = std.process.Environ.Map.init(alloc);
    defer current.deinit();
    try current.put("PATH", "/usr/bin");
    try current.put("KEEP", "same");
    try current.put("GONE", "x");
    try current.put("PWD", "/somewhere");
    const raw = begin_marker ++ "alias ll='ls -l'\n" ++ env_marker ++ "PATH=/opt/bin:/usr/bin\x00KEEP=same\x00NEW=va=lue\x00PWD=/else\x00";
    var script: []u8 = undefined;
    var delta: [][]const u8 = undefined;
    try testing.expect(try assemble(alloc, raw, &current, &script, &delta));
    defer alloc.free(script);
    defer {
        for (delta) |d| alloc.free(d);
        alloc.free(delta);
    }
    try testing.expect(std.mem.indexOf(u8, script, "alias ll='ls -l'") != null);
    try testing.expect(std.mem.startsWith(u8, script, "# fx-shell-snapshot-v1\n{\nunset BASH_ENV\n"));
    var got_path = false;
    var got_new = false;
    var got_unset = false;
    for (delta) |d| {
        if (std.mem.eql(u8, d, "@PATH\x00/opt/bin:\x00")) got_path = true;
        if (std.mem.eql(u8, d, "NEW=va=lue")) got_new = true;
        if (std.mem.eql(u8, d, "-u\x00GONE")) got_unset = true;
        try testing.expect(!std.mem.startsWith(u8, d, "KEEP="));
        try testing.expect(!std.mem.startsWith(u8, d, "PWD="));
    }
    try testing.expect(got_path and got_new and got_unset);
    try testing.expect(!try assemble(alloc, "no markers", &current, &script, &delta));
}

test "warm snapshot matches login shell output and skips the profile after the first run" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    std.Io.Dir.accessAbsolute(io_mod.getIo(), "/bin/bash", .{}) catch return error.SkipZigTest;
    std.Io.Dir.accessAbsolute(io_mod.getIo(), "/usr/bin/env", .{}) catch return error.SkipZigTest;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const profile = try std.fmt.allocPrint(alloc,
        \\export PATH="$HOME/bin:$PATH"
        \\export FX_WARM_MARK=from-profile
        \\alias fxgreet='printf "hello alias"'
        \\fxfunc() {{ printf 'func:%s' "$1"; }}
        \\shopt -s nullglob
        \\printf x >> "$HOME/profile-runs"
        \\
    , .{});
    defer alloc.free(profile);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = ".bash_profile", .data = profile });

    var env = try testEnv(alloc, home);
    defer env.deinit();
    const cache = try std.fs.path.join(alloc, &.{ home, "cache" });
    defer alloc.free(cache);
    const opts: Options = .{ .shell_path = "/bin/bash", .home = home, .cache_dir = cache, .env = &env };

    const command = "fxgreet; printf ' '; fxfunc 7; printf ' %s' \"$FX_WARM_MARK\"; case \":$PATH:\" in *\":$HOME/bin:\"*) printf ' path-ok';; esac; shopt -q nullglob && printf ' nullglob'";
    const login = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "/bin/bash", "--login", "-O", "expand_aliases", "-c", command },
        .environ_map = &env,
    });
    defer alloc.free(login.stdout);
    defer alloc.free(login.stderr);

    var resolved_local = try resolve(alloc, opts);
    defer resolved_local.deinit();
    var argv_arena = std.heap.ArenaAllocator.init(alloc);
    defer argv_arena.deinit();
    const argv = try resolved_local.argvWith(argv_arena.allocator(), env.get("PATH"), command);
    const warm = try std.process.run(alloc, io_mod.getIo(), .{ .argv = argv, .environ_map = &env });
    defer alloc.free(warm.stdout);
    defer alloc.free(warm.stderr);
    try testing.expectEqualStrings(login.stdout, warm.stdout);
    try testing.expectEqualStrings("hello alias func:7 from-profile path-ok nullglob", warm.stdout);
    try testing.expectEqualStrings("", warm.stderr);

    const warm2 = try std.process.run(alloc, io_mod.getIo(), .{ .argv = argv, .environ_map = &env });
    defer alloc.free(warm2.stdout);
    defer alloc.free(warm2.stderr);
    try testing.expectEqualStrings(warm.stdout, warm2.stdout);

    var runs = try tmp.dir.openFile(io_mod.getIo(), "profile-runs", .{});
    defer runs.close(io_mod.getIo());
    const count = try io_mod.readFileToEnd(alloc, &runs, 1024);
    defer alloc.free(count);
    try testing.expectEqualStrings("xx", count);

    var again = try resolve(alloc, opts);
    defer again.deinit();
    var runs2 = try tmp.dir.openFile(io_mod.getIo(), "profile-runs", .{});
    defer runs2.close(io_mod.getIo());
    const count2 = try io_mod.readFileToEnd(alloc, &runs2, 1024);
    defer alloc.free(count2);
    try testing.expectEqualStrings("xx", count2);
}
