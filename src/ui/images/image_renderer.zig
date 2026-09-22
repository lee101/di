// Transcript image slots: kitty graphics blocks (transmit + reserved rows +
// direct placement) or a height-stable text fallback line. Owns payload caching
// and drives the kitty_graphics budget.
const std = @import("std");
const image_attachments = @import("../../core/images/image_attachments.zig");
const io_mod = @import("../../core/shared/io.zig");
const kitty_graphics = @import("kitty_graphics.zig");
const types = @import("../../core/shared/types.zig");

const reset_style = "\x1b[0m";

pub const Key = u64;

const user_key_ns: Key = 1 << 62;
const tool_key_ns: Key = 2 << 62;
const key_index_mask: Key = 0x3fff_ffff_ffff_ffff;

pub fn userKey(id: usize) Key {
    return user_key_ns | (@as(Key, @intCast(id)) & key_index_mask);
}

pub fn toolKey(entry_id: u32, index: usize) Key {
    return tool_key_ns | (@as(Key, entry_id) << 24) | (@as(Key, @intCast(index)) & 0xff_ffff);
}

pub const Source = struct {
    key: Key,
    name: []const u8,
    mime_type: []const u8,
    inline_data: ?[]const u8 = null,
    base64: ?[]const u8 = null,
    path: ?[]const u8 = null,

    pub fn fromAttachment(key: Key, attachment: types.ImageAttachment) Source {
        return .{
            .key = key,
            .name = std.fs.path.basename(attachment.path),
            .mime_type = attachment.media_type,
            .inline_data = attachment.inline_data,
            .path = attachment.snapshot_path orelse attachment.path,
        };
    }
};

pub const Mode = enum { kitty, fallback };

pub const Caps = struct {
    graphics: bool = false,
    tmux: bool = false,
};

pub fn detectCaps() Caps {
    return .{
        .graphics = kitty_graphics.detectGraphicsFromProcess(),
        .tmux = kitty_graphics.tmuxActive(),
    };
}

pub const Layout = struct {
    max_columns: u16,
    cell: kitty_graphics.CellDimensions = .{},
};

pub const Plan = struct {
    mode: Mode,
    kitty_id: u32 = 0,
    dims: ?kitty_graphics.Dimensions = null,
    base64: []const u8 = "",
};

const meta_slot_count = 64;

const MetaSlot = struct {
    key: Key = 0,
    used: bool = false,
    dims_loaded: bool = false,
    name: [128]u8 = undefined,
    name_len: u16 = 0,
    mime: [64]u8 = undefined,
    mime_len: u16 = 0,
    dims: ?kitty_graphics.Dimensions = null,
};

const PayloadSlot = struct {
    key: Key = 0,
    used: bool = false,
    base64: []u8 = &.{},
};

var meta_slots: [meta_slot_count]MetaSlot = [_]MetaSlot{.{}} ** meta_slot_count;
var meta_next: usize = 0;
var payload_slots: [kitty_graphics.max_live_images]PayloadSlot = [_]PayloadSlot{.{}} ** kitty_graphics.max_live_images;
var dim_style: []const u8 = "";

// Retained payloads use a dedicated allocator with precise frees so caller
// arenas and test leak tracking never see cache-lifetime memory.
const payload_alloc = std.heap.page_allocator;

pub fn setDimStyle(style: []const u8) void {
    dim_style = style;
}

pub fn resetState() void {
    for (&payload_slots) |*slot| {
        if (slot.used) payload_alloc.free(slot.base64);
        slot.* = .{};
    }
    meta_slots = [_]MetaSlot{.{}} ** meta_slot_count;
    meta_next = 0;
}

fn metaLookup(key: Key) ?*MetaSlot {
    for (&meta_slots) |*slot| {
        if (slot.used and slot.key == key) return slot;
    }
    return null;
}

fn claimMeta(source: Source) *MetaSlot {
    if (metaLookup(source.key)) |slot| return slot;
    const slot = &meta_slots[meta_next % meta_slot_count];
    meta_next += 1;
    slot.* = .{};
    slot.used = true;
    slot.key = source.key;
    slot.name_len = @intCast(@min(source.name.len, slot.name.len));
    @memcpy(slot.name[0..slot.name_len], source.name[0..slot.name_len]);
    slot.mime_len = @intCast(@min(source.mime_type.len, slot.mime.len));
    @memcpy(slot.mime[0..slot.mime_len], source.mime_type[0..slot.mime_len]);
    return slot;
}

fn findPayloadSlot(key: Key) ?*PayloadSlot {
    for (&payload_slots) |*slot| {
        if (slot.used and slot.key == key) return slot;
    }
    return null;
}

fn freePayloadSlot(key: Key) void {
    const slot = findPayloadSlot(key) orelse return;
    payload_alloc.free(slot.base64);
    slot.* = .{};
}

fn claimPayloadSlot(budget: *kitty_graphics.Budget, key: Key) *PayloadSlot {
    if (findPayloadSlot(key)) |slot| return slot;
    for (&payload_slots) |*slot| {
        if (!slot.used) return slot;
    }
    for (&payload_slots) |*slot| {
        if (budget.lookup(slot.key) == null) {
            payload_alloc.free(slot.base64);
            slot.* = .{};
            return slot;
        }
    }
    const slot = &payload_slots[0];
    payload_alloc.free(slot.base64);
    slot.* = .{};
    return slot;
}

fn encodeBase64Owned(raw: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try payload_alloc.alloc(u8, encoder.calcSize(raw.len));
    errdefer payload_alloc.free(out);
    _ = encoder.encode(out, raw);
    return out;
}

fn base64Dims(encoded: []const u8) ?kitty_graphics.Dimensions {
    var buf: [32]u8 = undefined;
    const take = @min(buf.len, encoded.len & ~@as(usize, 3));
    if (take == 0) return null;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded[0..take]) catch return null;
    if (size > buf.len) return null;
    _ = decoder.decode(buf[0..size], encoded[0..take]) catch return null;
    return kitty_graphics.parsePngDimensions(buf[0..size]);
}

fn loadRawBytes(alloc: std.mem.Allocator, source: Source) !?[]u8 {
    if (source.base64 != null) return null;
    if (source.inline_data) |data| return try alloc.dupe(u8, data);
    const path = source.path orelse return null;
    const zio = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(zio, path, .{}) catch return null;
    defer file.close(zio);
    return io_mod.readFileToEnd(alloc, &file, image_attachments.max_image_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn resolveDimsOnly(alloc: std.mem.Allocator, source: Source, meta: *MetaSlot) !void {
    if (meta.dims_loaded) return;
    if (source.base64) |encoded| {
        meta.dims = base64Dims(encoded);
        meta.dims_loaded = true;
        return;
    }
    const raw = (try loadRawBytes(alloc, source)) orelse {
        meta.dims_loaded = true;
        return;
    };
    defer alloc.free(raw);
    meta.dims = kitty_graphics.parsePngDimensions(raw);
    meta.dims_loaded = true;
}

/// Decides how one image renders and admits it to the budget. Call before
/// building inline badges: badge text is hidden exactly when the kitty render
/// takes over (mode == .kitty). Idempotent per key.
pub fn admitImage(
    alloc: std.mem.Allocator,
    source: Source,
    budget: *kitty_graphics.Budget,
    caps: Caps,
) !Plan {
    const meta = claimMeta(source);
    if (!caps.graphics) {
        try resolveDimsOnly(alloc, source, meta);
        return .{ .mode = .fallback, .dims = meta.dims };
    }
    if (budget.isDemoted(source.key)) {
        try resolveDimsOnly(alloc, source, meta);
        return .{ .mode = .fallback, .dims = meta.dims };
    }
    if (findPayloadSlot(source.key)) |slot| {
        const id = budget.admit(source.key).kitty_id orelse {
            freePayloadSlot(source.key);
            return .{ .mode = .fallback, .dims = meta.dims };
        };
        return .{ .mode = .kitty, .kitty_id = id, .dims = meta.dims, .base64 = slot.base64 };
    }

    if (source.base64) |encoded| {
        if (!meta.dims_loaded) {
            meta.dims = base64Dims(encoded);
            meta.dims_loaded = true;
        }
        const dims = meta.dims orelse return .{ .mode = .fallback, .dims = meta.dims };
        const id = budget.admit(source.key).kitty_id orelse
            return .{ .mode = .fallback, .dims = meta.dims };
        const owned = try payload_alloc.dupe(u8, encoded);
        const slot = claimPayloadSlot(budget, source.key);
        slot.* = .{};
        slot.used = true;
        slot.key = source.key;
        slot.base64 = owned;
        return .{ .mode = .kitty, .kitty_id = id, .dims = dims, .base64 = slot.base64 };
    }

    const raw = (try loadRawBytes(alloc, source)) orelse {
        meta.dims_loaded = true;
        return .{ .mode = .fallback, .dims = meta.dims };
    };
    defer alloc.free(raw);
    if (!meta.dims_loaded) {
        meta.dims = kitty_graphics.parsePngDimensions(raw);
        meta.dims_loaded = true;
    }
    if (!kitty_graphics.isPng(raw)) return .{ .mode = .fallback, .dims = meta.dims };
    const dims = meta.dims orelse return .{ .mode = .fallback, .dims = meta.dims };
    const id = budget.admit(source.key).kitty_id orelse
        return .{ .mode = .fallback, .dims = meta.dims };
    const owned = try encodeBase64Owned(raw);
    const slot = claimPayloadSlot(budget, source.key);
    slot.* = .{};
    slot.used = true;
    slot.key = source.key;
    slot.base64 = owned;
    return .{ .mode = .kitty, .kitty_id = id, .dims = dims, .base64 = slot.base64 };
}

fn writeFallbackRow(
    writer: *std.Io.Writer,
    name: []const u8,
    mime: []const u8,
    dims: ?kitty_graphics.Dimensions,
) !void {
    try writer.writeAll(reset_style);
    try writer.writeAll(dim_style);
    try writer.print("[Image: {s} {s} ", .{ name, mime });
    if (dims) |value| {
        try writer.print("{d}x{d}", .{ value.width, value.height });
    } else {
        try writer.writeAll("?x?");
    }
    try writer.writeAll("]\n");
}

/// Delete + fallback for every budget eviction not yet emitted: the oldest
/// graphic is purged from the terminal and its slot demotes to text.
fn flushPending(
    writer: *std.Io.Writer,
    budget: *kitty_graphics.Budget,
    tmux: bool,
) !void {
    while (budget.takePending()) |eviction| {
        try kitty_graphics.writeDeleteImage(writer, eviction.kitty_id, tmux);
        try writer.writeByte('\n');
        if (metaLookup(eviction.key)) |meta| {
            try writeFallbackRow(
                writer,
                meta.name[0..meta.name_len],
                meta.mime[0..meta.mime_len],
                meta.dims,
            );
        } else {
            try writeFallbackRow(writer, "image", "?", null);
        }
        freePayloadSlot(eviction.key);
    }
}

/// Renders one image's slot rows (each row newline-terminated, every escape a
/// complete self-contained sequence): either the kitty block (chunked transmit
/// on the first reserved row, direct placement on the last) or the fallback
/// line. Flushes pending budget demotions first.
pub fn render(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    source: Source,
    budget: *kitty_graphics.Budget,
    layout: Layout,
    caps: Caps,
) !Mode {
    const plan = try admitImage(alloc, source, budget, caps);
    try flushPending(writer, budget, caps.tmux);
    switch (plan.mode) {
        .fallback => try writeFallbackRow(writer, source.name, source.mime_type, plan.dims),
        .kitty => {
            const dims = plan.dims orelse {
                try writeFallbackRow(writer, source.name, source.mime_type, null);
                return .fallback;
            };
            const fit = kitty_graphics.fitToWidth(dims, layout.max_columns, layout.cell);
            var row: u16 = 0;
            while (row < fit.rows) : (row += 1) {
                if (row == 0) {
                    try kitty_graphics.writeTransmit(writer, plan.base64, plan.kitty_id, caps.tmux);
                }
                if (row + 1 == fit.rows) {
                    if (fit.rows > 1) {
                        try writer.writeAll("\x1b7");
                        try writer.print("\x1b[{d}A", .{fit.rows - 1});
                    }
                    try kitty_graphics.writePlacement(
                        writer,
                        plan.kitty_id,
                        plan.kitty_id,
                        fit.columns,
                        fit.rows,
                        caps.tmux,
                    );
                    if (fit.rows > 1) try writer.writeAll("\x1b8");
                }
                try writer.writeByte('\n');
            }
        },
    }
    return plan.mode;
}

fn testPng(width: u32, height: u32, buf: *[24]u8) []const u8 {
    @memset(buf, 0);
    @memcpy(buf[0..8], kitty_graphics.png_magic);
    std.mem.writeInt(u32, buf[16..20], width, .big);
    std.mem.writeInt(u32, buf[20..24], height, .big);
    return buf;
}

test "png transmit and placement render a complete kitty block" {
    const alloc = std.testing.allocator;
    defer resetState();
    setDimStyle("");
    var budget: kitty_graphics.Budget = .{};
    var png_buf: [24]u8 = undefined;
    const png = testPng(36, 18, &png_buf);
    const source = Source{
        .key = userKey(1),
        .name = "shot.png",
        .mime_type = "image/png",
        .inline_data = png,
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const mode = try render(
        alloc,
        &out.writer,
        source,
        &budget,
        .{ .max_columns = 8 },
        .{ .graphics = true, .tmux = false },
    );
    try std.testing.expectEqual(Mode.kitty, mode);

    var expected: std.Io.Writer.Allocating = .init(alloc);
    defer expected.deinit();
    const encoder = std.base64.standard.Encoder;
    const encoded = try alloc.alloc(u8, encoder.calcSize(png.len));
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, png);
    try expected.writer.print("\x1b_Ga=t,f=100,q=2,i=1;{s}\x1b\\", .{encoded});
    try expected.writer.writeByte('\n');
    try expected.writer.writeAll("\x1b7\x1b[1A");
    try expected.writer.writeAll("\x1b_Ga=p,q=2,i=1,p=1,c=8,r=2,C=1\x1b\\");
    try expected.writer.writeAll("\x1b8\n");
    try std.testing.expectEqualStrings(expected.written(), out.written());
}

test "non-png bytes render the text fallback even with graphics enabled" {
    const alloc = std.testing.allocator;
    defer resetState();
    setDimStyle("");
    var budget: kitty_graphics.Budget = .{};
    const source = Source{
        .key = userKey(2),
        .name = "anim.gif",
        .mime_type = "image/gif",
        .inline_data = "GIF89a not a png",
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const mode = try render(
        alloc,
        &out.writer,
        source,
        &budget,
        .{ .max_columns = 8 },
        .{ .graphics = true, .tmux = false },
    );
    try std.testing.expectEqual(Mode.fallback, mode);
    try std.testing.expectEqualStrings("\x1b[0m[Image: anim.gif image/gif ?x?]\n", out.written());
}

test "base64 tool image payload transmits verbatim" {
    const alloc = std.testing.allocator;
    defer resetState();
    setDimStyle("");
    var budget: kitty_graphics.Budget = .{};
    var png_buf: [24]u8 = undefined;
    const png = testPng(36, 18, &png_buf);
    const encoder = std.base64.standard.Encoder;
    const encoded = try alloc.alloc(u8, encoder.calcSize(png.len));
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, png);

    const source = Source{
        .key = toolKey(9, 0),
        .name = "capture",
        .mime_type = "image/png",
        .base64 = encoded,
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const mode = try render(
        alloc,
        &out.writer,
        source,
        &budget,
        .{ .max_columns = 8 },
        .{ .graphics = true, .tmux = false },
    );
    try std.testing.expectEqual(Mode.kitty, mode);
    try std.testing.expect(std.mem.find(
        u8,
        out.written(),
        "\x1b_Ga=t,f=100,q=2,i=1;",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        out.written(),
        "\x1b_Ga=p,q=2,i=1,p=1,c=8,r=2,C=1\x1b\\",
    ) != null);
}

test "budget demotion emits delete and fallback" {
    const alloc = std.testing.allocator;
    defer resetState();
    setDimStyle("");
    var budget: kitty_graphics.Budget = .{};
    var png_buf: [24]u8 = undefined;
    const png = testPng(36, 18, &png_buf);
    const names = [_][]const u8{
        "one.png",   "two.png",   "three.png",
        "four.png",  "five.png",  "six.png",
        "seven.png", "eight.png", "nine.png",
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (names, 0..) |name, index| {
        const source = Source{
            .key = userKey(index + 1),
            .name = name,
            .mime_type = "image/png",
            .inline_data = png,
        };
        _ = try render(
            alloc,
            &out.writer,
            source,
            &budget,
            .{ .max_columns = 8 },
            .{ .graphics = true, .tmux = false },
        );
    }

    const text = out.written();
    const delete_at = std.mem.find(u8, text, "\x1b_Ga=d,d=I,i=1,q=2\x1b\\") orelse
        return error.MissingDeleteSequence;
    const fallback_at = std.mem.find(u8, text, "[Image: one.png image/png 36x18]") orelse
        return error.MissingFallbackLine;
    try std.testing.expect(delete_at < fallback_at);
    try std.testing.expect(std.mem.find(u8, text, "\x1b_Ga=t,f=100,q=2,i=9;") != null);

    var again: std.Io.Writer.Allocating = .init(alloc);
    defer again.deinit();
    const demoted = Source{
        .key = userKey(1),
        .name = "one.png",
        .mime_type = "image/png",
        .inline_data = png,
    };
    const mode = try render(
        alloc,
        &again.writer,
        demoted,
        &budget,
        .{ .max_columns = 8 },
        .{ .graphics = true, .tmux = false },
    );
    try std.testing.expectEqual(Mode.fallback, mode);
    try std.testing.expectEqualStrings("\x1b[0m[Image: one.png image/png 36x18]\n", again.written());
}

test "FX_NO_KITTY_IMAGES opt-out yields fallback only" {
    const alloc = std.testing.allocator;
    defer resetState();
    setDimStyle("");
    try std.testing.expect(!kitty_graphics.detectGraphics(.{
        .fx_no_kitty_images = "1",
        .kitty_window_id = "3",
    }));
    try std.testing.expect(kitty_graphics.detectGraphics(.{ .kitty_window_id = "3" }));
    try std.testing.expect(kitty_graphics.detectGraphics(.{ .fx_kitty_images = "1" }));
    try std.testing.expect(!kitty_graphics.detectGraphics(.{ .fx_kitty_images = "1", .fx_no_kitty_images = "1" }));
    try std.testing.expect(!kitty_graphics.detectGraphics(.{ .fx_kitty_images = "0" }));
    try std.testing.expect(kitty_graphics.detectGraphics(.{ .term = "xterm-kitty" }));
    try std.testing.expect(kitty_graphics.detectGraphics(.{ .term_program = "WezTerm" }));
    try std.testing.expect(kitty_graphics.detectGraphics(.{ .ghostty_resources_dir = "/res" }));
    try std.testing.expect(!kitty_graphics.detectGraphics(.{ .term = "xterm-256color" }));

    var budget: kitty_graphics.Budget = .{};
    var png_buf: [24]u8 = undefined;
    const png = testPng(36, 18, &png_buf);
    const source = Source{
        .key = userKey(1),
        .name = "shot.png",
        .mime_type = "image/png",
        .inline_data = png,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const mode = try render(
        alloc,
        &out.writer,
        source,
        &budget,
        .{ .max_columns = 8 },
        .{ .graphics = false, .tmux = false },
    );
    try std.testing.expectEqual(Mode.fallback, mode);
    try std.testing.expectEqualStrings("\x1b[0m[Image: shot.png image/png 36x18]\n", out.written());
}
