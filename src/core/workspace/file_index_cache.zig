//! Persisted workspace file index for instant @-completion on launch.
//!
//! One file per workspace scope under `<home>/.fx/file-index/<sha>.idx`:
//! magic + SHA-256 of the payload + JSON payload listing the scope roots and
//! every indexed path with its kind. Freshness is advisory only: a background
//! rescan always follows a cache load and replaces it, and the index is a
//! completion aid, never a correctness boundary.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const file_index = @import("file_index.zig");
const compress_mod = @import("../shared/compress.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const magic_v1 = "fx-file-index-v1\n";
const magic = "fx-file-index-v2\n";
pub const max_bytes = 64 * 1024 * 1024;

const Candidate = file_index.Candidate;

const Payload = struct {
    written_at_ms: i64,
    roots: []const []const u8,
    entries: []const Entry,

    const Entry = struct {
        path: []const u8,
        kind: u8,
    };
};

pub const Loaded = struct {
    written_at_ms: i64,
    /// Owned candidate slice; each path is owned by the same allocator.
    candidates: []Candidate,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        for (self.candidates) |candidate| alloc.free(candidate.path);
        alloc.free(self.candidates);
        self.* = undefined;
    }
};

fn cacheKeyHex(alloc: Allocator, roots: []const []const u8) ![]u8 {
    var digest = Sha256.init(.{});
    for (roots) |root| {
        digest.update(root);
        digest.update(&.{0});
    }
    var sum: [Sha256.digest_length]u8 = undefined;
    digest.final(&sum);
    const hex = std.fmt.bytesToHex(sum, .lower);
    return try alloc.dupe(u8, &hex);
}

fn cachePath(alloc: Allocator, home: []const u8, roots: []const []const u8) ![]u8 {
    const key = try cacheKeyHex(alloc, roots);
    defer alloc.free(key);
    return try std.fmt.allocPrint(alloc, "{s}/.fx/file-index/{s}.idx", .{ home, key });
}

/// Loads the persisted index for `roots` under `$HOME`, or null when absent,
/// unreadable, or invalid. All validation failures degrade to a rescan.
pub fn load(alloc: Allocator, roots: []const []const u8) !?Loaded {
    const home = io_mod.getenv("HOME") orelse return null;
    return loadFrom(alloc, home, roots);
}

/// Loads from an explicit home directory (tests and non-HOME callers).
pub fn loadFrom(alloc: Allocator, home: []const u8, roots: []const []const u8) !?Loaded {
    const path = try cachePath(alloc, home, roots);
    defer alloc.free(path);
    return loadPath(alloc, path, roots) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.FileNotFound => null,
        else => blk: {
            debug_trace.logf("core", "file index cache ignored err={s}", .{@errorName(err)});
            break :blk null;
        },
    };
}

fn readAllBounded(alloc: Allocator, file: *std.Io.File, size: u64) ![]u8 {
    const zio = io_mod.getIo();
    const bytes = try alloc.alloc(u8, @intCast(size));
    errdefer alloc.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + 64 * 1024);
        const read = try file.readPositionalAll(zio, bytes[offset..end], offset);
        if (read != end - offset) return error.InvalidIndexCache;
        offset = end;
    }
    return bytes;
}

pub const MigrateResult = struct { before: u64, after: u64 };

/// Rewrites a v1 cache file as v2 (compressed) after a verified round trip.
/// Already-v2 or invalid files are left untouched (`before == after`).
pub fn migrateFile(alloc: Allocator, path: []const u8) !MigrateResult {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{ .follow_symlinks = false, .allow_directory = false });
    const stat = try file.stat(zio);
    if (stat.kind != .file or stat.nlink != 1 or stat.size > max_bytes) {
        file.close(zio);
        return .{ .before = stat.size, .after = stat.size };
    }
    const bytes = readAllBounded(alloc, &file, stat.size) catch |err| {
        file.close(zio);
        return err;
    };
    file.close(zio);
    defer alloc.free(bytes);
    if (!std.mem.startsWith(u8, bytes, magic_v1)) return .{ .before = stat.size, .after = stat.size };
    const payload = decodePayload(alloc, bytes) catch return .{ .before = stat.size, .after = stat.size };
    defer alloc.free(payload);
    var out = try encodeFile(alloc, payload);
    defer out.deinit();
    const check = try decodePayload(alloc, out.written());
    defer alloc.free(check);
    if (!std.mem.eql(u8, check, payload)) return error.InvalidIndexCache;
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidIndexCache;
    var dir = try std.Io.Dir.openDirAbsolute(zio, dir_path, .{ .follow_symlinks = false, .iterate = true });
    defer dir.close(zio);
    var verified: io_mod.VerifiedDir = .{ .dir = dir };
    try io_mod.durableReplaceVerified(alloc, &verified, std.fs.path.basename(path), out.written());
    return .{ .before = stat.size, .after = out.written().len };
}

/// Returns the verified uncompressed JSON payload of a v1 (plain) or v2
/// (codec byte + digest + possibly compressed) file. Caller owns the slice.
fn decodePayload(alloc: Allocator, bytes: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, bytes, magic_v1)) {
        if (bytes.len < magic_v1.len + Sha256.digest_length) return error.InvalidIndexCache;
        const payload = bytes[magic_v1.len + Sha256.digest_length ..];
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(payload, &digest, .{});
        if (!std.mem.eql(u8, &digest, bytes[magic_v1.len..][0..Sha256.digest_length])) return error.InvalidIndexCache;
        return alloc.dupe(u8, payload);
    }
    if (!std.mem.startsWith(u8, bytes, magic) or bytes.len < magic.len + 1 + Sha256.digest_length) return error.InvalidIndexCache;
    const codec = std.enums.fromInt(compress_mod.Codec, bytes[magic.len]) orelse return error.InvalidIndexCache;
    const digest_at = magic.len + 1;
    const body = bytes[digest_at + Sha256.digest_length ..];
    const payload = compress_mod.decompress(alloc, codec, body, max_bytes + 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidIndexCache,
    };
    errdefer alloc.free(payload);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[digest_at..][0..Sha256.digest_length])) return error.InvalidIndexCache;
    return payload;
}

fn encodeFile(alloc: Allocator, payload: []const u8) !std.Io.Writer.Allocating {
    const packed_payload = try compress_mod.compress(alloc, payload, .{});
    defer alloc.free(packed_payload.bytes);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(magic);
    try out.writer.writeByte(@intFromEnum(packed_payload.codec));
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload, &digest, .{});
    try out.writer.writeAll(&digest);
    try out.writer.writeAll(packed_payload.bytes);
    return out;
}

fn loadPath(alloc: Allocator, path: []const u8, roots: []const []const u8) !?Loaded {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{ .follow_symlinks = false, .allow_directory = false });
    defer file.close(zio);
    const stat = try file.stat(zio);
    if (stat.kind != .file or stat.nlink != 1 or (stat.permissions.toMode() & 0o077) != 0 or stat.size > max_bytes) return error.InvalidIndexCache;
    const bytes = try readAllBounded(alloc, &file, stat.size);
    defer alloc.free(bytes);
    const payload = try decodePayload(alloc, bytes);
    defer alloc.free(payload);
    var parsed = try std.json.parseFromSlice(Payload, alloc, payload, .{ .allocate = .alloc_if_needed, .ignore_unknown_fields = false, .max_value_len = max_bytes });
    defer parsed.deinit();
    const value = parsed.value;
    if (value.written_at_ms < 0 or value.roots.len == 0) return error.InvalidIndexCache;
    if (value.entries.len > file_index.max_indexed_files) return error.InvalidIndexCache;
    if (value.roots.len != roots.len) return error.InvalidIndexCache;
    for (value.roots, roots) |cached, expected| {
        if (!std.mem.eql(u8, cached, expected)) return error.InvalidIndexCache;
    }
    var candidates = try std.ArrayList(Candidate).initCapacity(alloc, value.entries.len);
    errdefer {
        for (candidates.items) |candidate| alloc.free(candidate.path);
        candidates.deinit(alloc);
    }
    for (value.entries) |entry| {
        if (entry.path.len == 0 or entry.path.len > file_index.max_path_len) return error.InvalidIndexCache;
        if (!text_utils.isTerminalSafe(entry.path)) return error.InvalidIndexCache;
        const kind: file_index.CandidateKind = switch (entry.kind) {
            0 => .file,
            1 => .directory,
            else => return error.InvalidIndexCache,
        };
        candidates.appendAssumeCapacity(.{
            .path = try alloc.dupe(u8, entry.path),
            .kind = kind,
        });
    }
    return .{
        .written_at_ms = value.written_at_ms,
        .candidates = try candidates.toOwnedSlice(alloc),
    };
}

/// Persists the index for `roots` under `$HOME`. Best-effort by contract:
/// callers log and continue on failure because the in-memory index is
/// already complete.
pub fn save(alloc: Allocator, roots: []const []const u8, candidates: []const Candidate) !void {
    const home = io_mod.getenv("HOME") orelse return;
    return saveTo(alloc, home, roots, candidates);
}

/// Saves under an explicit home directory (tests and non-HOME callers).
pub fn saveTo(alloc: Allocator, home: []const u8, roots: []const []const u8, candidates: []const Candidate) !void {
    if (roots.len == 0) return;
    const path = try cachePath(alloc, home, roots);
    defer alloc.free(path);
    if (candidates.len == 0) {
        // An empty index paints nothing, so never create one. If a prior scan
        // persisted entries and the workspace is now empty, drop the stale
        // file instead of serving ghosts.
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    const zio = io_mod.getIo();
    const dir_path = std.fs.path.dirname(path) orelse return;
    try io_mod.makeDirRecursive(dir_path);

    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    const writer = &payload.writer;
    try writer.writeAll("{\"written_at_ms\":");
    try writer.print("{d}", .{io_mod.milliTimestamp()});
    try writer.writeAll(",\"roots\":");
    try std.json.Stringify.value(roots, .{}, writer);
    try writer.writeAll(",\"entries\":[");
    var written: usize = 0;
    for (candidates) |candidate| {
        if (candidate.path.len == 0 or candidate.path.len > file_index.max_path_len) continue;
        if (!text_utils.isTerminalSafe(candidate.path)) continue;
        if (written > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try std.json.Stringify.value(candidate.path, .{}, writer);
        try writer.print(",\"kind\":{d}}}", .{@intFromEnum(candidate.kind)});
        written += 1;
        if (payload.written().len > max_bytes) return error.IndexCacheTooLarge;
    }
    try writer.writeAll("]}");

    var out = try encodeFile(alloc, payload.written());
    defer out.deinit();

    // `.iterate` matters on Linux: without it the descriptor is O_PATH and
    // the directory fsync inside durableReplaceVerified fails with EBADF.
    var dir = try std.Io.Dir.openDirAbsolute(zio, dir_path, .{ .follow_symlinks = false, .iterate = true });
    defer dir.close(zio);
    var verified: io_mod.VerifiedDir = .{ .dir = dir };
    try io_mod.durableReplaceVerified(alloc, &verified, std.fs.path.basename(path), out.written());
    try dir.setPermissions(zio, .fromMode(0o700));
}

test "file index cache round trips and rejects tampering" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const roots = [_][]const u8{"/workspace"};
    const candidates = [_]Candidate{
        .{ .path = "src/main.zig", .kind = .file },
        .{ .path = "docs", .kind = .directory },
    };

    try std.testing.expect((try loadFrom(alloc, home, &roots)) == null);
    try saveTo(alloc, home, &roots, &candidates);
    var loaded = (try loadFrom(alloc, home, &roots)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), loaded.candidates.len);
    try std.testing.expectEqualStrings("src/main.zig", loaded.candidates[0].path);
    try std.testing.expectEqual(.directory, loaded.candidates[1].kind);

    // A different scope must never reuse this file.
    const other_roots = [_][]const u8{"/elsewhere"};
    try std.testing.expect((try loadFrom(alloc, home, &other_roots)) == null);

    // Bit flips break the digest and degrade to a rescan.
    const path = try cachePath(alloc, home, &roots);
    defer alloc.free(path);
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, "X", magic.len + 1 + Sha256.digest_length + 4);
    file.close(std.testing.io);
    try std.testing.expect((try loadFrom(alloc, home, &roots)) == null);

    // Unsafe entries never reach disk: a save of only-unsafe paths produces a
    // valid but empty index, and the next load filters nothing further.
    const evil = [_]Candidate{.{ .path = "bad\x1bpath", .kind = .file }};
    try saveTo(alloc, home, &roots, &evil);
    var empty = (try loadFrom(alloc, home, &roots)).?;
    defer empty.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), empty.candidates.len);

    // An empty scan deletes the persisted index rather than serving ghosts.
    try saveTo(alloc, home, &roots, &.{});
    try std.testing.expect((try loadFrom(alloc, home, &roots)) == null);
}

test "v1 cache files still load and migrate to smaller v2 files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const roots = [_][]const u8{"/legacy"};
    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |c| alloc.free(c.path);
        candidates.deinit(alloc);
    }
    for (0..3000) |i| try candidates.append(alloc, .{ .path = try std.fmt.allocPrint(alloc, "src/pkg{d}/module{d}.zig", .{ i % 30, i }), .kind = .file });

    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.print("{{\"written_at_ms\":5,\"roots\":[\"/legacy\"],\"entries\":[", .{});
    for (candidates.items, 0..) |c, i| {
        if (i > 0) try payload.writer.writeByte(',');
        try payload.writer.print("{{\"path\":\"{s}\",\"kind\":0}}", .{c.path});
    }
    try payload.writer.writeAll("]}");
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(payload.written(), &digest, .{});
    var v1: std.Io.Writer.Allocating = .init(alloc);
    defer v1.deinit();
    try v1.writer.writeAll(magic_v1);
    try v1.writer.writeAll(&digest);
    try v1.writer.writeAll(payload.written());

    const path = try cachePath(alloc, home, &roots);
    defer alloc.free(path);
    try io_mod.makeDirRecursive(std.fs.path.dirname(path).?);
    try io_mod.writeFileAtomic(alloc, path, v1.written());
    {
        var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.setPermissions(std.testing.io, .fromMode(0o600));
    }

    var loaded = (try loadFrom(alloc, home, &roots)).?;
    try std.testing.expectEqual(@as(usize, 3000), loaded.candidates.len);
    loaded.deinit(alloc);

    const result = try migrateFile(alloc, path);
    try std.testing.expectEqual(@as(u64, v1.written().len), result.before);
    try std.testing.expect(result.after * 4 < result.before);
    var again = (try loadFrom(alloc, home, &roots)).?;
    defer again.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3000), again.candidates.len);
    try std.testing.expectEqualStrings("src/pkg0/module0.zig", again.candidates[0].path);
    const second = try migrateFile(alloc, path);
    try std.testing.expectEqual(second.before, second.after);
}
