//! Cold-data compression. zstd is written through a runtime-loaded libzstd
//! (no build-time dependency); when it is absent, data is written as zlib
//! deflate from std. Reading zstd never needs libzstd: std decodes it.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const Codec = enum(u8) {
    none = 0,
    zstd = 1,
    deflate = 2,
};

pub const Compressed = struct {
    codec: Codec,
    bytes: []u8,
};

const zstd_window_len: u32 = 4 * 1024 * 1024;
const zstd_magic = [4]u8{ 0x28, 0xb5, 0x2f, 0xfd };

const ZstdApi = struct {
    lib: std.DynLib,
    compress: *const fn (dst: [*]u8, dst_cap: usize, src: [*]const u8, src_len: usize, level: c_int) callconv(.c) usize,
    bound: *const fn (src_len: usize) callconv(.c) usize,
    is_error: *const fn (code: usize) callconv(.c) c_uint,
    decompress: *const fn (dst: [*]u8, dst_cap: usize, src: [*]const u8, src_len: usize) callconv(.c) usize,
};

var api_state: std.atomic.Value(u8) = .init(0);
var api: ZstdApi = undefined;

fn loadApi() ?*const ZstdApi {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return null;
    if (comptime !builtin.link_libc) return null;
    while (true) {
        switch (api_state.load(.acquire)) {
            2 => return &api,
            3 => return null,
            1 => std.atomic.spinLoopHint(),
            else => if (api_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
                api_state.store(if (tryLoad()) 2 else 3, .release);
            },
        }
    }
}

fn tryLoad() bool {
    if (std.c.getenv("FX_DISABLE_LIBZSTD") != null) return false;
    const names = [_][]const u8{ "libzstd.so.1", "libzstd.dylib", "libzstd.so" };
    for (names) |name| {
        var lib = std.DynLib.open(name) catch continue;
        const c = lib.lookup(@TypeOf(api.compress), "ZSTD_compress") orelse {
            lib.close();
            continue;
        };
        const b = lib.lookup(@TypeOf(api.bound), "ZSTD_compressBound") orelse {
            lib.close();
            continue;
        };
        const e = lib.lookup(@TypeOf(api.is_error), "ZSTD_isError") orelse {
            lib.close();
            continue;
        };
        const d = lib.lookup(@TypeOf(api.decompress), "ZSTD_decompress") orelse {
            lib.close();
            continue;
        };
        api = .{ .lib = lib, .compress = c, .bound = b, .is_error = e, .decompress = d };
        return true;
    }
    return false;
}

pub fn zstdAvailable() bool {
    return loadApi() != null;
}

pub const Options = struct {
    level: c_int = 3,
    allow_zstd: bool = true,
};

/// Never returns a result larger than the input: incompressible data comes back as `.none`.
pub fn compress(alloc: Allocator, input: []const u8, options: Options) !Compressed {
    if (options.allow_zstd) if (loadApi()) |z| {
        const cap = z.bound(input.len);
        const out = try alloc.alloc(u8, cap);
        errdefer alloc.free(out);
        const n = z.compress(out.ptr, cap, input.ptr, input.len, options.level);
        if (z.is_error(n) == 0 and n < input.len) {
            return .{ .codec = .zstd, .bytes = try alloc.realloc(out, n) };
        }
        alloc.free(out);
        return .{ .codec = .none, .bytes = try alloc.dupe(u8, input) };
    };
    var out = try std.Io.Writer.Allocating.initCapacity(alloc, @max(4096, input.len / 4));
    errdefer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&out.writer, &window, .zlib, .default);
    try c.writer.writeAll(input);
    try c.finish();
    if (out.written().len >= input.len) {
        out.deinit();
        return .{ .codec = .none, .bytes = try alloc.dupe(u8, input) };
    }
    return .{ .codec = .deflate, .bytes = try out.toOwnedSlice() };
}

pub const DecompressError = error{ CorruptCompressedData, OutputTooLarge } || Allocator.Error;

pub fn decompress(alloc: Allocator, codec: Codec, input: []const u8, max_out: usize) DecompressError![]u8 {
    switch (codec) {
        .none => {
            if (input.len > max_out) return error.OutputTooLarge;
            return alloc.dupe(u8, input);
        },
        .zstd => return decompressZstd(alloc, input, max_out),
        .deflate => {
            var reader: std.Io.Reader = .fixed(input);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var d: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
            return finish(alloc, &d.reader, max_out);
        },
    }
}

fn decompressZstd(alloc: Allocator, input: []const u8, max_out: usize) DecompressError![]u8 {
    if (input.len < 4 or !std.mem.eql(u8, input[0..4], &zstd_magic)) return error.CorruptCompressedData;
    if (frameContentSize(input)) |size| {
        if (size > max_out) return error.OutputTooLarge;
        if (loadApi()) |z| {
            const out = try alloc.alloc(u8, size);
            errdefer alloc.free(out);
            const n = z.decompress(out.ptr, size, input.ptr, input.len);
            if (z.is_error(n) != 0 or n != size) return error.CorruptCompressedData;
            return out;
        }
    }
    return decompressZstdStd(alloc, input, max_out);
}

pub fn decompressZstdStd(alloc: Allocator, input: []const u8, max_out: usize) DecompressError![]u8 {
    const buf = try alloc.alloc(u8, zstd_window_len + std.compress.zstd.block_size_max);
    defer alloc.free(buf);
    var reader: std.Io.Reader = .fixed(input);
    var d: std.compress.zstd.Decompress = .init(&reader, buf, .{ .window_len = zstd_window_len });
    return finish(alloc, &d.reader, max_out);
}

fn finish(alloc: Allocator, reader: *std.Io.Reader, max_out: usize) DecompressError![]u8 {
    const out = reader.allocRemaining(alloc, .limited(max_out +| 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.OutputTooLarge,
        error.ReadFailed => return error.CorruptCompressedData,
    };
    if (out.len > max_out) {
        alloc.free(out);
        return error.OutputTooLarge;
    }
    return out;
}

fn frameContentSize(input: []const u8) ?usize {
    if (input.len < 6) return null;
    const fhd = input[4];
    const fcs_flag = fhd >> 6;
    const single_segment = (fhd >> 5) & 1 == 1;
    const dict_flag = fhd & 3;
    var off: usize = 5;
    if (!single_segment) off += 1;
    off += switch (dict_flag) {
        0 => @as(usize, 0),
        1 => 1,
        2 => 2,
        else => 4,
    };
    const size_bytes: usize = switch (fcs_flag) {
        0 => if (single_segment) 1 else return null,
        1 => 2,
        2 => 4,
        else => 8,
    };
    if (input.len < off + size_bytes) return null;
    var v: u64 = 0;
    var i: usize = 0;
    while (i < size_bytes) : (i += 1) v |= @as(u64, input[off + i]) << @intCast(8 * i);
    if (fcs_flag == 1) v += 256;
    return std.math.cast(usize, v);
}

test "round trip through every codec" {
    const alloc = std.testing.allocator;
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    for (0..4000) |i| try text.writer.print("{{\"path\":\"src/dir{d}/file{d}.zig\",\"kind\":0}},", .{ i % 40, i });

    const z = try compress(alloc, text.written(), .{});
    defer alloc.free(z.bytes);
    try std.testing.expect(z.codec != .none);
    try std.testing.expect(z.bytes.len * 4 < text.written().len);
    const back = try decompress(alloc, z.codec, z.bytes, 1 << 20);
    defer alloc.free(back);
    try std.testing.expectEqualStrings(text.written(), back);

    const d = try compress(alloc, text.written(), .{ .allow_zstd = false });
    defer alloc.free(d.bytes);
    try std.testing.expectEqual(Codec.deflate, d.codec);
    const back2 = try decompress(alloc, .deflate, d.bytes, 1 << 20);
    defer alloc.free(back2);
    try std.testing.expectEqualStrings(text.written(), back2);
}

test "zstd frames written by libzstd decode with std when available" {
    if (!zstdAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const input = "hello hello hello hello hello hello hello hello hello hello hello hello hello hello hello";
    const z = try compress(alloc, input, .{});
    defer alloc.free(z.bytes);
    try std.testing.expectEqual(Codec.zstd, z.codec);
    const via_std = try decompressZstdStd(alloc, z.bytes, 1024);
    defer alloc.free(via_std);
    try std.testing.expectEqualStrings(input, via_std);
}

test "incompressible and corrupt inputs are handled" {
    const alloc = std.testing.allocator;
    var rnd: [512]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&rnd);
    const c = try compress(alloc, &rnd, .{});
    defer alloc.free(c.bytes);
    try std.testing.expectEqual(Codec.none, c.codec);
    try std.testing.expectError(error.CorruptCompressedData, decompress(alloc, .zstd, "not zstd at all", 100));
    try std.testing.expectError(error.CorruptCompressedData, decompress(alloc, .deflate, "garbage garbage garbage", 100));
    const big = try compress(alloc, "a" ** 5000, .{});
    defer alloc.free(big.bytes);
    try std.testing.expectError(error.OutputTooLarge, decompress(alloc, big.codec, big.bytes, 100));
}
