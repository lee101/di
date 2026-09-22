// Kitty graphics protocol: transmit/placement/delete encoders, terminal
// capability detection, PNG header parsing, and the inline image budget.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");

/// Base64 payload is cut into 3072-char chunks so every emitted control
/// string (params, chunk, tmux passthrough doubling) stays under the terminal
/// engine's 4096-byte control-string budget; multi-chunk transmits mark
/// non-final chunks m=1 and the final chunk m=0.
pub const base64_chunk_len: usize = 3072;
pub const max_live_images: usize = 8;
pub const max_demoted_images: usize = 64;
pub const max_pending_evictions: usize = 64;

pub const png_magic = "\x89PNG\r\n\x1a\n";

pub const Dimensions = struct { width: u32, height: u32 };

pub const CellDimensions = struct {
    width_px: u32 = 9,
    height_px: u32 = 18,
};

pub const Fit = struct { columns: u16, rows: u16 };

pub fn isPng(bytes: []const u8) bool {
    return bytes.len >= png_magic.len and
        std.mem.eql(u8, bytes[0..png_magic.len], png_magic);
}

/// PNG IHDR width/height live at bytes 16..24, big-endian.
pub fn parsePngDimensions(bytes: []const u8) ?Dimensions {
    if (!isPng(bytes) or bytes.len < 24) return null;
    const width = (@as(u32, bytes[16]) << 24) |
        (@as(u32, bytes[17]) << 16) |
        (@as(u32, bytes[18]) << 8) |
        @as(u32, bytes[19]);
    const height = (@as(u32, bytes[20]) << 24) |
        (@as(u32, bytes[21]) << 16) |
        (@as(u32, bytes[22]) << 8) |
        @as(u32, bytes[23]);
    return .{ .width = width, .height = height };
}

fn writeEscapedBytes(writer: *std.Io.Writer, tmux: bool, bytes: []const u8) !void {
    if (!tmux) return writer.writeAll(bytes);
    for (bytes) |byte| {
        if (byte == 0x1b) try writer.writeAll("\x1b\x1b") else try writer.writeByte(byte);
    }
}

/// Writes one APC (`ESC_G<params>[;<payload>]ESC\`). When `tmux` the whole APC
/// is wrapped in a DCS passthrough with every inner ESC doubled.
fn writeApc(writer: *std.Io.Writer, tmux: bool, params: []const u8, payload: ?[]const u8) !void {
    if (tmux) try writer.writeAll("\x1bPtmux;");
    try writeEscapedBytes(writer, tmux, "\x1b_G");
    try writeEscapedBytes(writer, tmux, params);
    if (payload) |data| {
        try writeEscapedBytes(writer, tmux, ";");
        try writeEscapedBytes(writer, tmux, data);
    }
    try writeEscapedBytes(writer, tmux, "\x1b\\");
    if (tmux) try writer.writeAll("\x1b\\");
}

/// Chunked PNG transmit keyed by `image_id` (f=100: PNG payload, no transcoding).
/// Base64 payload is cut into `base64_chunk_len` chunks; multi-chunk transmits mark
/// non-final chunks m=1 and the final chunk m=0.
pub fn writeTransmit(writer: *std.Io.Writer, base64: []const u8, image_id: u32, tmux: bool) !void {
    if (base64.len <= base64_chunk_len) {
        var buf: [96]u8 = undefined;
        const params = try std.fmt.bufPrint(&buf, "a=t,f=100,q=2,i={d}", .{image_id});
        return writeApc(writer, tmux, params, base64);
    }
    var offset: usize = 0;
    var first = true;
    while (offset < base64.len) {
        const end = @min(offset + base64_chunk_len, base64.len);
        const is_last = end == base64.len;
        var buf: [96]u8 = undefined;
        const params = if (first)
            try std.fmt.bufPrint(&buf, "a=t,f=100,q=2,i={d},m=1", .{image_id})
        else if (is_last)
            try std.fmt.bufPrint(&buf, "q=2,m=0", .{})
        else
            try std.fmt.bufPrint(&buf, "q=2,m=1", .{});
        try writeApc(writer, tmux, params, base64[offset..end]);
        first = false;
        offset = end;
    }
}

/// Direct placement of a previously transmitted image. `C=1` keeps the cursor
/// at the placement origin; carrying `placement_id` makes re-emission replace
/// the placement in place instead of stacking.
pub fn writePlacement(
    writer: *std.Io.Writer,
    image_id: u32,
    placement_id: u32,
    columns: u32,
    rows: u32,
    tmux: bool,
) !void {
    var buf: [96]u8 = undefined;
    const params = try std.fmt.bufPrint(
        &buf,
        "a=p,q=2,i={d},p={d},c={d},r={d},C=1",
        .{ image_id, placement_id, columns, rows },
    );
    try writeApc(writer, tmux, params, null);
}

/// `d=I` deletes the image and every placement of it, on screen and in
/// scrollback, and frees the transmitted payload.
pub fn writeDeleteImage(writer: *std.Io.Writer, image_id: u32, tmux: bool) !void {
    var buf: [64]u8 = undefined;
    const params = try std.fmt.bufPrint(&buf, "a=d,d=I,i={d},q=2", .{image_id});
    try writeApc(writer, tmux, params, null);
}

pub const Env = struct {
    kitty_window_id: ?[]const u8 = null,
    ghostty_resources_dir: ?[]const u8 = null,
    term: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    fx_no_kitty_images: ?[]const u8 = null,
    fx_kitty_images: ?[]const u8 = null,
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Kitty graphics support: kitty/ghostty/wezterm/warp families only; unknown
/// terminals get the text fallback. `FX_NO_KITTY_IMAGES=1` is a hard opt-out.
pub fn detectGraphics(env: Env) bool {
    if (env.fx_no_kitty_images) |value| {
        if (std.mem.eql(u8, value, "1")) return false;
    }
    // Explicit opt-in wins over detection gaps (for example a tmux server
    // that stripped KITTY_WINDOW_ID from the pane environment).
    if (env.fx_kitty_images) |value| {
        if (std.mem.eql(u8, value, "1")) return true;
    }
    if (env.kitty_window_id != null) return true;
    if (env.ghostty_resources_dir != null) return true;
    if (env.term) |term| {
        if (std.ascii.indexOfIgnoreCase(term, "kitty") != null) return true;
    }
    if (env.term_program) |program| {
        if (eqlIgnoreCase(program, "kitty") or
            eqlIgnoreCase(program, "ghostty") or
            eqlIgnoreCase(program, "wezterm") or
            eqlIgnoreCase(program, "warpterminal")) return true;
    }
    return false;
}

pub fn detectGraphicsFromProcess() bool {
    return detectGraphics(.{
        .kitty_window_id = io_mod.getenv("KITTY_WINDOW_ID"),
        .ghostty_resources_dir = io_mod.getenv("GHOSTTY_RESOURCES_DIR"),
        .term = io_mod.getenv("TERM"),
        .term_program = io_mod.getenv("TERM_PROGRAM"),
        .fx_no_kitty_images = io_mod.getenv("FX_NO_KITTY_IMAGES"),
        .fx_kitty_images = io_mod.getenv("FX_KITTY_IMAGES"),
    });
}

pub fn tmuxActive() bool {
    return io_mod.getenv("TMUX") != null;
}

/// Cell box an image occupies when fitted to `max_columns` cells at `cell`
/// resolution. Small images scale up to fill the width (matching the reference
/// fit); rows round up so the placement box always covers the scaled image.
pub fn fitToWidth(dims: Dimensions, max_columns: u16, cell: CellDimensions) Fit {
    const img_w: u64 = @max(dims.width, 1);
    const img_h: u64 = @max(dims.height, 1);
    const columns: u64 = @max(max_columns, 1);
    const max_w_px = columns * cell.width_px;
    const denominator = img_w * cell.height_px;
    const rows = (img_h * max_w_px + denominator - 1) / denominator;
    return .{
        .columns = @intCast(@min(columns, std.math.maxInt(u16))),
        .rows = @intCast(@min(@max(rows, 1), std.math.maxInt(u16))),
    };
}

pub const Eviction = struct { key: u64, kitty_id: u32 };

/// Admission result for one image: its stable kitty id, or null once the image
/// has been demoted and its slot must render the text fallback.
pub const Admission = struct {
    kitty_id: ?u32,
    evicted: ?Eviction = null,
};

/// Transcript-wide inline image budget: at most `max_live_images` live kitty
/// graphics, newest kept first. Over capacity the oldest graphic is evicted
/// (queued for `d=I` deletion plus a fallback line) and its key is demoted
/// forever so rebuilt slots render text instead of resurrecting pixels.
pub const Budget = struct {
    next_id: u32 = 1,
    live_keys: [max_live_images]u64 = undefined,
    live_ids: [max_live_images]u32 = undefined,
    live_count: usize = 0,
    demoted_keys: [max_demoted_images]u64 = undefined,
    demoted_count: usize = 0,
    pending: [max_pending_evictions]Eviction = undefined,
    pending_count: usize = 0,

    pub fn reset(self: *Budget) void {
        self.* = .{};
    }

    pub fn lookup(self: *const Budget, key: u64) ?u32 {
        for (self.live_keys[0..self.live_count], self.live_ids[0..self.live_count]) |live_key, id| {
            if (live_key == key) return id;
        }
        return null;
    }

    pub fn isDemoted(self: *const Budget, key: u64) bool {
        const count = @min(self.demoted_count, max_demoted_images);
        const start = self.demoted_count -% count;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const slot = (start + i) % max_demoted_images;
            if (self.demoted_keys[slot] == key) return true;
        }
        return false;
    }

    fn recordDemoted(self: *Budget, key: u64) void {
        self.demoted_keys[self.demoted_count % max_demoted_images] = key;
        self.demoted_count +%= 1;
    }

    fn queueEviction(self: *Budget, eviction: Eviction) void {
        if (self.pending_count == max_pending_evictions) {
            std.mem.copyForwards(
                Eviction,
                self.pending[0 .. max_pending_evictions - 1],
                self.pending[1..max_pending_evictions],
            );
            self.pending_count -= 1;
        }
        self.pending[self.pending_count] = eviction;
        self.pending_count += 1;
    }

    /// Idempotent per key: live keys keep their id; demoted keys stay demoted.
    /// A fresh key gets the next monotonic id, evicting the oldest live entry
    /// when over capacity.
    pub fn admit(self: *Budget, key: u64) Admission {
        if (self.lookup(key)) |id| return .{ .kitty_id = id };
        if (self.isDemoted(key)) return .{ .kitty_id = null };
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        var evicted: ?Eviction = null;
        if (self.live_count == max_live_images) {
            const oldest = Eviction{
                .key = self.live_keys[0],
                .kitty_id = self.live_ids[0],
            };
            std.mem.copyForwards(
                u64,
                self.live_keys[0 .. max_live_images - 1],
                self.live_keys[1..max_live_images],
            );
            std.mem.copyForwards(
                u32,
                self.live_ids[0 .. max_live_images - 1],
                self.live_ids[1..max_live_images],
            );
            self.recordDemoted(oldest.key);
            self.queueEviction(oldest);
            evicted = oldest;
        } else {
            self.live_count += 1;
        }
        self.live_keys[self.live_count - 1] = key;
        self.live_ids[self.live_count - 1] = id;
        return .{ .kitty_id = id, .evicted = evicted };
    }

    pub fn takePending(self: *Budget) ?Eviction {
        if (self.pending_count == 0) return null;
        const eviction = self.pending[0];
        std.mem.copyForwards(
            Eviction,
            self.pending[0 .. self.pending_count - 1],
            self.pending[1..self.pending_count],
        );
        self.pending_count -= 1;
        return eviction;
    }
};

pub var transcript_budget: Budget = .{};

test "transmit escape for short payload carries the full control data" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeTransmit(&out.writer, "QUJDRA==", 3, false);
    try std.testing.expectEqualStrings("\x1b_Ga=t,f=100,q=2,i=3;QUJDRA==\x1b\\", out.written());
}

test "transmit payload over one chunk forces m=1 then m=0 chunks" {
    const alloc = std.testing.allocator;
    const payload = try alloc.alloc(u8, base64_chunk_len * 2 + 3);
    defer alloc.free(payload);
    @memset(payload, 'A');

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeTransmit(&out.writer, payload, 7, false);

    var expected: std.Io.Writer.Allocating = .init(alloc);
    defer expected.deinit();
    try expected.writer.print("\x1b_Ga=t,f=100,q=2,i=7,m=1;{s}\x1b\\", .{payload[0..base64_chunk_len]});
    try expected.writer.print("\x1b_Gq=2,m=1;{s}\x1b\\", .{payload[base64_chunk_len .. base64_chunk_len * 2]});
    try expected.writer.print("\x1b_Gq=2,m=0;{s}\x1b\\", .{payload[base64_chunk_len * 2 ..]});
    try std.testing.expectEqualStrings(expected.written(), out.written());
}

test "placement escape carries computed columns and rows" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writePlacement(&out.writer, 7, 7, 30, 12, false);
    try std.testing.expectEqualStrings("\x1b_Ga=p,q=2,i=7,p=7,c=30,r=12,C=1\x1b\\", out.written());
}

test "delete escape purges image data by id" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeDeleteImage(&out.writer, 4, false);
    try std.testing.expectEqualStrings("\x1b_Ga=d,d=I,i=4,q=2\x1b\\", out.written());
}

test "tmux passthrough wrapping doubles inner escapes" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeDeleteImage(&out.writer, 4, true);
    try std.testing.expectEqualStrings(
        "\x1bPtmux;\x1b\x1b_Ga=d,d=I,i=4,q=2\x1b\x1b\\\x1b\\",
        out.written(),
    );

    const payload = try alloc.alloc(u8, base64_chunk_len * 2 + 3);
    defer alloc.free(payload);
    @memset(payload, 'A');
    var chunked: std.Io.Writer.Allocating = .init(alloc);
    defer chunked.deinit();
    try writeTransmit(&chunked.writer, payload, 2, true);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, chunked.written(), "\x1bPtmux;"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, chunked.written(), "\x1b\x1b_G"));
}

test "png magic detection and ihdr dimension parse" {
    var bytes: [24]u8 = undefined;
    @memset(&bytes, 0);
    @memcpy(bytes[0..8], png_magic);
    std.mem.writeInt(u32, bytes[16..20], 300, .big);
    std.mem.writeInt(u32, bytes[20..24], 200, .big);

    try std.testing.expect(isPng(&bytes));
    try std.testing.expect(!isPng("GIF89a definitely not a png"));
    const dims = parsePngDimensions(&bytes).?;
    try std.testing.expectEqual(Dimensions{ .width = 300, .height = 200 }, dims);
    try std.testing.expectEqual(@as(?Dimensions, null), parsePngDimensions(bytes[0..23]));
    try std.testing.expectEqual(@as(?Dimensions, null), parsePngDimensions("GIF89a definitely not a png"));
}

test "fit computes columns and rows from pixel dimensions" {
    const fit = fitToWidth(.{ .width = 300, .height = 200 }, 20, .{});
    try std.testing.expectEqual(Fit{ .columns = 20, .rows = 7 }, fit);

    const tiny = fitToWidth(.{ .width = 4, .height = 4 }, 10, .{});
    try std.testing.expectEqual(Fit{ .columns = 10, .rows = 5 }, tiny);

    const degenerate = fitToWidth(.{ .width = 0, .height = 0 }, 0, .{});
    try std.testing.expectEqual(Fit{ .columns = 1, .rows = 1 }, degenerate);
}

test "budget keeps newest images and demotes the oldest" {
    var budget: Budget = .{};
    for (0..max_live_images) |index| {
        const admission = budget.admit(index + 1);
        try std.testing.expectEqual(@as(?u32, @intCast(index + 1)), admission.kitty_id);
        try std.testing.expectEqual(@as(?Eviction, null), admission.evicted);
    }

    const ninth = budget.admit(9);
    try std.testing.expectEqual(@as(?u32, 9), ninth.kitty_id);
    try std.testing.expectEqual(Eviction{ .key = 1, .kitty_id = 1 }, ninth.evicted.?);
    try std.testing.expect(budget.isDemoted(1));
    try std.testing.expectEqual(@as(?u32, null), budget.lookup(1));
    try std.testing.expectEqual(@as(?u32, 2), budget.lookup(2));

    const demoted_readmit = budget.admit(1);
    try std.testing.expectEqual(@as(?u32, null), demoted_readmit.kitty_id);
    try std.testing.expectEqual(@as(?Eviction, null), demoted_readmit.evicted);

    const pending = budget.takePending().?;
    try std.testing.expectEqual(Eviction{ .key = 1, .kitty_id = 1 }, pending);
    try std.testing.expectEqual(@as(?Eviction, null), budget.takePending());

    const live_readmit = budget.admit(5);
    try std.testing.expectEqual(@as(?u32, 5), live_readmit.kitty_id);
    try std.testing.expectEqual(@as(?Eviction, null), live_readmit.evicted);

    budget.reset();
    try std.testing.expectEqual(@as(?u32, 1), budget.admit(10).kitty_id);
}
