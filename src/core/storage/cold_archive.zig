//! Reversible cold storage for session tool-result artifacts and log files.
//!
//! An archived file `NAME` becomes `NAME.fxz` in the same directory. The
//! original is removed only after the archive was written durably and decoded
//! back to identical bytes. Readers restore lazily (`restoreInDir`), so
//! sessions stay readable and resumable without a separate migration step.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const compress = @import("../shared/compress.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const suffix = ".fxz";
const magic = "FXZ1";
const header_len = 4 + 1 + 3 + 8 + Sha256.digest_length;
pub const max_file_bytes: usize = 256 * 1024 * 1024;
pub const default_min_bytes: u64 = 4096;

pub fn isArchiveName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, suffix) and name.len > suffix.len;
}

pub fn encode(alloc: Allocator, input: []const u8, options: compress.Options) !?[]u8 {
    const packed_data = try compress.compress(alloc, input, options);
    defer alloc.free(packed_data.bytes);
    if (packed_data.codec == .none) return null;
    var out = try std.Io.Writer.Allocating.initCapacity(alloc, header_len + packed_data.bytes.len);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(magic);
    try w.writeByte(@intFromEnum(packed_data.codec));
    try w.splatByteAll(0, 3);
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, input.len, .little);
    try w.writeAll(&len_buf);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    try w.writeAll(&digest);
    try w.writeAll(packed_data.bytes);
    return try out.toOwnedSlice();
}

pub const DecodeError = error{InvalidArchive} || compress.DecompressError;

pub fn decode(alloc: Allocator, archive: []const u8) DecodeError![]u8 {
    if (archive.len < header_len or !std.mem.eql(u8, archive[0..4], magic)) return error.InvalidArchive;
    const codec = std.enums.fromInt(compress.Codec, archive[4]) orelse return error.InvalidArchive;
    const orig_len = std.mem.readInt(u64, archive[8..16], .little);
    if (orig_len > max_file_bytes) return error.InvalidArchive;
    const want = archive[16..][0..Sha256.digest_length];
    const out = try compress.decompress(alloc, codec, archive[header_len..], @intCast(orig_len));
    errdefer alloc.free(out);
    if (out.len != orig_len) return error.InvalidArchive;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(out, &digest, .{});
    if (!std.mem.eql(u8, &digest, want)) return error.InvalidArchive;
    return out;
}

fn readFile(alloc: Allocator, dir: std.Io.Dir, name: []const u8, max: usize) ![]u8 {
    var file = try io_mod.openExistingRegularFile(dir, name, .read_only);
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max);
}

pub const Saved = struct { before: u64 = 0, after: u64 = 0 };

pub const ArchiveOutcome = enum { archived, skipped_small, skipped_incompressible, skipped_exists };

/// Archives `name` in `dir` when it is at least `min_bytes` and compresses.
/// Returns the byte counts through `saved`.
pub fn archiveInDir(
    alloc: Allocator,
    dir: std.Io.Dir,
    name: []const u8,
    min_bytes: u64,
    options: compress.Options,
    saved: *Saved,
) !ArchiveOutcome {
    const archive_name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ name, suffix });
    defer alloc.free(archive_name);
    const st = try dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false });
    if (st.kind != .file or st.nlink != 1) return error.NotRegular;
    if (st.size < min_bytes or st.size > max_file_bytes) return .skipped_small;
    if (dir.statFile(io_mod.getIo(), archive_name, .{ .follow_symlinks = false })) |_| {
        return .skipped_exists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const original = try readFile(alloc, dir, name, max_file_bytes);
    defer alloc.free(original);
    const encoded = (try encode(alloc, original, options)) orelse return .skipped_incompressible;
    defer alloc.free(encoded);
    if (encoded.len + encoded.len / 10 > original.len) return .skipped_incompressible;

    var verified: io_mod.VerifiedDir = .{ .dir = dir };
    try io_mod.durableReplaceVerified(alloc, &verified, archive_name, encoded);
    const check_bytes = try readFile(alloc, dir, archive_name, max_file_bytes);
    defer alloc.free(check_bytes);
    const round = try decode(alloc, check_bytes);
    defer alloc.free(round);
    if (!std.mem.eql(u8, round, original)) {
        dir.deleteFile(io_mod.getIo(), archive_name) catch {};
        return error.InvalidArchive;
    }
    try dir.deleteFile(io_mod.getIo(), name);
    saved.before += original.len;
    saved.after += encoded.len;
    return .archived;
}

/// Restores `name` from `name.fxz`. Returns false when no archive exists.
pub fn restoreInDir(alloc: Allocator, dir: std.Io.Dir, name: []const u8) !bool {
    const archive_name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ name, suffix });
    defer alloc.free(archive_name);
    const archive = readFile(alloc, dir, archive_name, max_file_bytes + header_len + 1024) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer alloc.free(archive);
    const original = try decode(alloc, archive);
    defer alloc.free(original);
    var verified: io_mod.VerifiedDir = .{ .dir = dir };
    try io_mod.durableReplaceVerified(alloc, &verified, name, original);
    dir.deleteFile(io_mod.getIo(), archive_name) catch {};
    return true;
}

pub const Stats = struct {
    session_count: u64 = 0,
    events_bytes: u64 = 0,
    tool_result_files: u64 = 0,
    tool_result_bytes: u64 = 0,
    archived_files: u64 = 0,
    archived_bytes: u64 = 0,
    command_log_files: u64 = 0,
    command_log_bytes: u64 = 0,
    file_index_files: u64 = 0,
    file_index_bytes: u64 = 0,
    file_index_legacy_files: u64 = 0,
    log_bytes: u64 = 0,
    other_bytes: u64 = 0,
    total_bytes: u64 = 0,
    duplicate_result_files: u64 = 0,
    duplicate_result_bytes: u64 = 0,
};

fn dirSize(dir: std.Io.Dir, alloc: Allocator) !u64 {
    var total: u64 = 0;
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file) continue;
        const st = entry.dir.statFile(io_mod.getIo(), entry.basename, .{ .follow_symlinks = false }) catch continue;
        total += st.size;
    }
    return total;
}

pub fn stats(alloc: Allocator, fx_dir: []const u8) !Stats {
    var out: Stats = .{};
    var root = std.Io.Dir.openDirAbsolute(io_mod.getIo(), fx_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out,
        else => return err,
    };
    defer root.close(io_mod.getIo());
    out.total_bytes = try dirSize(root, alloc);

    if (root.openDir(io_mod.getIo(), "sessions", .{ .iterate = true, .follow_symlinks = false })) |sessions_open| {
        var sessions = sessions_open;
        defer sessions.close(io_mod.getIo());
        var seen = std.AutoHashMap(u64, void).init(alloc);
        defer seen.deinit();
        var it = sessions.iterate();
        while (try it.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            var sdir = sessions.openDir(io_mod.getIo(), entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
            defer sdir.close(io_mod.getIo());
            out.session_count += 1;
            if (sdir.statFile(io_mod.getIo(), "events.jsonl", .{})) |st| out.events_bytes += st.size else |_| {}
            if (sdir.openDir(io_mod.getIo(), "tool-results", .{ .iterate = true, .follow_symlinks = false })) |tr_open| {
                var tr = tr_open;
                defer tr.close(io_mod.getIo());
                var tit = tr.iterate();
                while (try tit.next(io_mod.getIo())) |f| {
                    if (f.kind != .file) continue;
                    const st = tr.statFile(io_mod.getIo(), f.name, .{ .follow_symlinks = false }) catch continue;
                    if (isArchiveName(f.name)) {
                        out.archived_files += 1;
                        out.archived_bytes += st.size;
                        continue;
                    }
                    out.tool_result_files += 1;
                    out.tool_result_bytes += st.size;
                    if (st.size >= default_min_bytes and st.size <= 8 * 1024 * 1024) {
                        const bytes = readFile(alloc, tr, f.name, 8 * 1024 * 1024) catch continue;
                        defer alloc.free(bytes);
                        const key = std.hash.Wyhash.hash(0x51ed, bytes);
                        if (seen.contains(key)) {
                            out.duplicate_result_files += 1;
                            out.duplicate_result_bytes += st.size;
                        } else try seen.put(key, {});
                    }
                }
            } else |_| {}
            if (sdir.openDir(io_mod.getIo(), "logs", .{ .iterate = true, .follow_symlinks = false })) |lg_open| {
                var lg = lg_open;
                defer lg.close(io_mod.getIo());
                const size = try dirSize(lg, alloc);
                out.command_log_bytes += size;
                var wit = try lg.walk(alloc);
                defer wit.deinit();
                while (try wit.next(io_mod.getIo())) |f| {
                    if (f.kind == .file) out.command_log_files += 1;
                }
            } else |_| {}
        }
    } else |_| {}

    if (root.openDir(io_mod.getIo(), "file-index", .{ .iterate = true, .follow_symlinks = false })) |fi_open| {
        var fi = fi_open;
        defer fi.close(io_mod.getIo());
        var it = fi.iterate();
        while (try it.next(io_mod.getIo())) |f| {
            if (f.kind != .file) continue;
            const st = fi.statFile(io_mod.getIo(), f.name, .{ .follow_symlinks = false }) catch continue;
            out.file_index_files += 1;
            out.file_index_bytes += st.size;
            var file = io_mod.openExistingRegularFile(fi, f.name, .read_only) catch continue;
            defer file.close(io_mod.getIo());
            var head: [17]u8 = undefined;
            const n = file.readPositionalAll(io_mod.getIo(), &head, 0) catch 0;
            if (std.mem.eql(u8, head[0..n], "fx-file-index-v1\n")) out.file_index_legacy_files += 1;
        }
    } else |_| {}

    if (root.openDir(io_mod.getIo(), "logs", .{ .iterate = true, .follow_symlinks = false })) |lg_open| {
        var lg = lg_open;
        defer lg.close(io_mod.getIo());
        out.log_bytes = try dirSize(lg, alloc);
    } else |_| {}

    const accounted = out.events_bytes + out.tool_result_bytes + out.archived_bytes + out.command_log_bytes + out.file_index_bytes + out.log_bytes;
    out.other_bytes = out.total_bytes -| accounted;
    return out;
}

pub const CompactOptions = struct {
    older_than_s: u64 = 7 * 86400,
    min_bytes: u64 = default_min_bytes,
    dry_run: bool = false,
    file_index: bool = true,
    sessions: bool = true,
    now_ms: i64 = 0,
};

pub const CompactReport = struct {
    archived_files: u64 = 0,
    archived_before: u64 = 0,
    archived_after: u64 = 0,
    sessions_touched: u64 = 0,
    sessions_skipped_live: u64 = 0,
    file_index_before: u64 = 0,
    file_index_after: u64 = 0,
    failures: u64 = 0,
};

fn ownerAlive(sdir: std.Io.Dir, alloc: Allocator) bool {
    const bytes = readFile(alloc, sdir, "owner.live", 4096) catch return false;
    defer alloc.free(bytes);
    const needle = "\"pid\":";
    const at = std.mem.indexOf(u8, bytes, needle) orelse return false;
    var end = at + needle.len;
    while (end < bytes.len and std.ascii.isDigit(bytes[end])) end += 1;
    const pid = std.fmt.parseInt(i32, bytes[at + needle.len .. end], 10) catch return false;
    if (pid <= 0) return false;
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return err == error.PermissionDenied;
    return true;
}

pub fn compact(alloc: Allocator, fx_dir: []const u8, options: CompactOptions) !CompactReport {
    var report: CompactReport = .{};
    var root = std.Io.Dir.openDirAbsolute(io_mod.getIo(), fx_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return report,
        else => return err,
    };
    defer root.close(io_mod.getIo());
    const now_ms = if (options.now_ms != 0) options.now_ms else io_mod.milliTimestamp();
    const cutoff_ns: i128 = (@as(i128, now_ms) - @as(i128, options.older_than_s) * 1000) * std.time.ns_per_ms;

    if (options.file_index) {
        if (root.openDir(io_mod.getIo(), "file-index", .{ .iterate = true, .follow_symlinks = false })) |fi_open| {
            var fi = fi_open;
            defer fi.close(io_mod.getIo());
            const file_index_cache = @import("../workspace/file_index_cache.zig");
            var it = fi.iterate();
            while (try it.next(io_mod.getIo())) |f| {
                if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".idx")) continue;
                const path = try std.fs.path.join(alloc, &.{ fx_dir, "file-index", f.name });
                defer alloc.free(path);
                if (options.dry_run) {
                    const st = fi.statFile(io_mod.getIo(), f.name, .{}) catch continue;
                    report.file_index_before += st.size;
                    report.file_index_after += st.size;
                    continue;
                }
                const r = file_index_cache.migrateFile(alloc, path) catch {
                    report.failures += 1;
                    continue;
                };
                report.file_index_before += r.before;
                report.file_index_after += r.after;
            }
        } else |_| {}
    }

    if (options.sessions) {
        var sessions = root.openDir(io_mod.getIo(), "sessions", .{ .iterate = true, .follow_symlinks = false }) catch return report;
        defer sessions.close(io_mod.getIo());
        var it = sessions.iterate();
        while (try it.next(io_mod.getIo())) |entry| {
            if (entry.kind != .directory) continue;
            var sdir = sessions.openDir(io_mod.getIo(), entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
            defer sdir.close(io_mod.getIo());
            const ev = sdir.statFile(io_mod.getIo(), "events.jsonl", .{}) catch continue;
            if (@as(i128, ev.mtime.nanoseconds) > cutoff_ns) continue;
            if (ownerAlive(sdir, alloc)) {
                report.sessions_skipped_live += 1;
                continue;
            }
            var tr = sdir.openDir(io_mod.getIo(), "tool-results", .{ .iterate = true, .follow_symlinks = false }) catch continue;
            defer tr.close(io_mod.getIo());
            var names: std.ArrayList([]u8) = .empty;
            defer {
                for (names.items) |n| alloc.free(n);
                names.deinit(alloc);
            }
            var tit = tr.iterate();
            while (try tit.next(io_mod.getIo())) |f| {
                if (f.kind != .file or isArchiveName(f.name) or f.name[0] == '.') continue;
                try names.append(alloc, try alloc.dupe(u8, f.name));
            }
            var touched = false;
            for (names.items) |name| {
                if (options.dry_run) {
                    const st = tr.statFile(io_mod.getIo(), name, .{}) catch continue;
                    if (st.size >= options.min_bytes) {
                        report.archived_files += 1;
                        report.archived_before += st.size;
                        touched = true;
                    }
                    continue;
                }
                var saved: Saved = .{};
                const outcome = archiveInDir(alloc, tr, name, options.min_bytes, .{}, &saved) catch {
                    report.failures += 1;
                    continue;
                };
                if (outcome == .archived) {
                    report.archived_files += 1;
                    report.archived_before += saved.before;
                    report.archived_after += saved.after;
                    touched = true;
                }
            }
            if (touched) report.sessions_touched += 1;
        }
    }
    return report;
}

pub fn restoreAll(alloc: Allocator, fx_dir: []const u8, only_session: ?[]const u8) !u64 {
    var root = std.Io.Dir.openDirAbsolute(io_mod.getIo(), fx_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer root.close(io_mod.getIo());
    var sessions = root.openDir(io_mod.getIo(), "sessions", .{ .iterate = true, .follow_symlinks = false }) catch return 0;
    defer sessions.close(io_mod.getIo());
    var restored: u64 = 0;
    var it = sessions.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        if (entry.kind != .directory) continue;
        if (only_session) |id| if (!std.mem.eql(u8, id, entry.name)) continue;
        var sdir = sessions.openDir(io_mod.getIo(), entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
        defer sdir.close(io_mod.getIo());
        var tr = sdir.openDir(io_mod.getIo(), "tool-results", .{ .iterate = true, .follow_symlinks = false }) catch continue;
        defer tr.close(io_mod.getIo());
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| alloc.free(n);
            names.deinit(alloc);
        }
        var tit = tr.iterate();
        while (try tit.next(io_mod.getIo())) |f| {
            if (f.kind != .file or !isArchiveName(f.name)) continue;
            try names.append(alloc, try alloc.dupe(u8, f.name[0 .. f.name.len - suffix.len]));
        }
        for (names.items) |name| {
            if (try restoreInDir(alloc, tr, name)) restored += 1;
        }
    }
    return restored;
}

const testing = std.testing;

fn makeCompressible(alloc: Allocator, n: usize) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    errdefer w.deinit();
    var i: usize = 0;
    while (w.written().len < n) : (i += 1) try w.writer.print("line {d}: the quick brown fox {d}\n", .{ i, i % 17 });
    return w.toOwnedSlice();
}

test "encode decode round trip and tamper detection" {
    const alloc = testing.allocator;
    const data = try makeCompressible(alloc, 20000);
    defer alloc.free(data);
    const enc = (try encode(alloc, data, .{})).?;
    defer alloc.free(enc);
    try testing.expect(enc.len * 3 < data.len);
    const dec = try decode(alloc, enc);
    defer alloc.free(dec);
    try testing.expectEqualSlices(u8, data, dec);
    enc[enc.len - 3] ^= 0x55;
    try testing.expect(std.meta.isError(decode(alloc, enc)));
    try testing.expectError(error.InvalidArchive, decode(alloc, "short"));
    try testing.expect((try encode(alloc, "tiny", .{})) == null);
}

fn writePrivate(alloc: Allocator, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var v: io_mod.VerifiedDir = .{ .dir = dir };
    try io_mod.durableReplaceVerified(alloc, &v, name, bytes);
}

test "archive then lazy restore is byte identical for both codecs" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const data = try makeCompressible(alloc, 50000);
    defer alloc.free(data);
    inline for (.{ true, false }) |zstd_ok| {
        const name = if (zstd_ok) "a.txt" else "b.txt";
        writePrivate(alloc, tmp.dir, name, data) catch |e| std.debug.panic("write {s}", .{@errorName(e)});
        var saved: Saved = .{};
        const outcome = archiveInDir(alloc, tmp.dir, name, 1024, .{ .allow_zstd = zstd_ok }, &saved) catch |e| std.debug.panic("archive {s}", .{@errorName(e)});
        try testing.expectEqual(ArchiveOutcome.archived, outcome);
        try testing.expect(saved.after * 3 < saved.before);
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(io_mod.getIo(), name, .{}));
        try testing.expect(try restoreInDir(alloc, tmp.dir, name));
        var f = try tmp.dir.openFile(io_mod.getIo(), name, .{});
        defer f.close(io_mod.getIo());
        const back = try io_mod.readFileToEnd(alloc, &f, 1 << 20);
        defer alloc.free(back);
        try testing.expectEqualSlices(u8, data, back);
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(io_mod.getIo(), name ++ suffix, .{}));
    }
    try testing.expect(!try restoreInDir(alloc, tmp.dir, "missing.txt"));
}

test "small and incompressible files are left alone" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writePrivate(alloc, tmp.dir, "small.txt", "hi");
    var saved: Saved = .{};
    try testing.expectEqual(ArchiveOutcome.skipped_small, try archiveInDir(alloc, tmp.dir, "small.txt", 4096, .{}, &saved));
    var rnd: [8192]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(&rnd);
    try writePrivate(alloc, tmp.dir, "rnd.bin", &rnd);
    try testing.expectEqual(ArchiveOutcome.skipped_incompressible, try archiveInDir(alloc, tmp.dir, "rnd.bin", 4096, .{}, &saved));
    _ = try tmp.dir.statFile(io_mod.getIo(), "rnd.bin", .{});
}

test "compact archives only cold sessions and restoreAll reverses it" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "fx/sessions/cold/tool-results");
    try tmp.dir.createDirPath(io_mod.getIo(), "fx/sessions/live/tool-results");
    const data = try makeCompressible(alloc, 30000);
    defer alloc.free(data);
    inline for (.{ "cold", "live" }) |id| {
        var sd = try tmp.dir.openDir(io_mod.getIo(), "fx/sessions/" ++ id, .{ .iterate = true });
        defer sd.close(io_mod.getIo());
        try writePrivate(alloc, sd, "events.jsonl", "{}\n");
        var td = try sd.openDir(io_mod.getIo(), "tool-results", .{ .iterate = true });
        defer td.close(io_mod.getIo());
        try writePrivate(alloc, td, "result-1.txt", data);
    }
    {
        var sd = try tmp.dir.openDir(io_mod.getIo(), "fx/sessions/live", .{ .iterate = true });
        defer sd.close(io_mod.getIo());
        const pid_json = try std.fmt.allocPrint(alloc, "{{\"pid\":{d}}}", .{std.c.getpid()});
        defer alloc.free(pid_json);
        try writePrivate(alloc, sd, "owner.live", pid_json);
    }
    const fx = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fx");
    defer alloc.free(fx);
    const far_future = io_mod.milliTimestamp() + 30 * 86400 * 1000;
    const dry = try compact(alloc, fx, .{ .dry_run = true, .now_ms = far_future });
    try testing.expectEqual(@as(u64, 1), dry.archived_files);
    const report = try compact(alloc, fx, .{ .now_ms = far_future });
    try testing.expectEqual(@as(u64, 1), report.archived_files);
    try testing.expectEqual(@as(u64, 1), report.sessions_skipped_live);
    try testing.expect(report.archived_after * 3 < report.archived_before);
    const s = try stats(alloc, fx);
    try testing.expectEqual(@as(u64, 1), s.archived_files);
    try testing.expectEqual(@as(u64, 1), s.tool_result_files);
    try testing.expectEqual(@as(u64, 2), s.session_count);
    try testing.expectEqual(@as(u64, 1), try restoreAll(alloc, fx, null));
    const s2 = try stats(alloc, fx);
    try testing.expectEqual(@as(u64, 0), s2.archived_files);
    try testing.expectEqual(@as(u64, 2), s2.tool_result_files);
    try testing.expectEqual(@as(u64, 1), s2.duplicate_result_files);
}
