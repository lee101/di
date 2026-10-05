//! The `auto_compact_percent` and `auto_compact_warm_percent` settings: how
//! full a request gets before fx-compactor runs on its own, and before it
//! runs right after a turn while the provider cache is warm.

const std = @import("std");

/// Automatic compaction starts once a request reaches this share of the
/// model's usable input window.
pub const default_percent: u8 = 80;
pub const min_percent: u8 = 10;
pub const max_percent: u8 = 80;

pub fn isValidPercent(value: u64) bool {
    return value >= min_percent and value <= max_percent;
}

/// Parses a process override. Invalid or out-of-range values are ignored.
fn parsePercent(raw: ?[]const u8) ?u8 {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseUnsigned(u8, trimmed, 10) catch return null;
    return if (isValidPercent(value)) value else null;
}

pub fn resolvePercent(configured: ?u8, process_override: ?[]const u8) u8 {
    return parsePercent(process_override) orelse configured orelse default_percent;
}

/// Warm compaction runs right after a turn that ended at this share of the
/// usable input, so the next turn starts small.
pub const default_warm_percent: u8 = 60;

/// 0 turns warm compaction off. Anything else must stay below the percent
/// where in-turn compaction starts.
pub fn isValidWarmPercent(value: u64) bool {
    return value == 0 or (value >= min_percent and value < max_percent);
}

fn parseWarmPercent(raw: ?[]const u8) ?u8 {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseUnsigned(u8, trimmed, 10) catch return null;
    return if (isValidWarmPercent(value)) value else null;
}

/// The warm percent in effect next to `auto_percent`. An unset value follows
/// the default, kept at three quarters of `auto_percent` when that is lower;
/// a set value at or above `auto_percent` leaves warm compaction off.
pub fn resolveWarmPercent(configured: ?u8, process_override: ?[]const u8, auto_percent: u8) u8 {
    const explicit = parseWarmPercent(process_override) orelse configured;
    const value = explicit orelse @min(default_warm_percent, @as(u8, @intCast(@as(u16, auto_percent) * 3 / 4)));
    return if (value >= auto_percent) 0 else value;
}

test "auto compaction percent accepts only the supported range" {
    try std.testing.expect(!isValidPercent(9));
    try std.testing.expect(isValidPercent(10));
    try std.testing.expect(isValidPercent(80));
    try std.testing.expect(!isValidPercent(81));
    try std.testing.expectEqual(@as(?u8, 50), parsePercent(" 50\n"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("5"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("90"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent("half"));
    try std.testing.expectEqual(@as(?u8, null), parsePercent(""));
}

test "auto compaction percent resolves override, then setting, then default" {
    try std.testing.expectEqual(default_percent, resolvePercent(null, null));
    try std.testing.expectEqual(@as(u8, 40), resolvePercent(40, null));
    try std.testing.expectEqual(@as(u8, 25), resolvePercent(40, "25"));
    try std.testing.expectEqual(@as(u8, 40), resolvePercent(40, "95"));
}

test "warm compaction percent accepts zero or a value below the automatic range" {
    try std.testing.expect(isValidWarmPercent(0));
    try std.testing.expect(!isValidWarmPercent(9));
    try std.testing.expect(isValidWarmPercent(10));
    try std.testing.expect(isValidWarmPercent(79));
    try std.testing.expect(!isValidWarmPercent(80));
    try std.testing.expectEqual(@as(?u8, 0), parseWarmPercent("0"));
    try std.testing.expectEqual(@as(?u8, 50), parseWarmPercent(" 50 "));
    try std.testing.expectEqual(@as(?u8, null), parseWarmPercent("80"));
    try std.testing.expectEqual(@as(?u8, null), parseWarmPercent("warm"));
}

test "warm compaction percent resolves override, then setting, then a default below the automatic percent" {
    try std.testing.expectEqual(@as(u8, 60), resolveWarmPercent(null, null, 80));
    try std.testing.expectEqual(@as(u8, 30), resolveWarmPercent(null, null, 40));
    try std.testing.expectEqual(@as(u8, 7), resolveWarmPercent(null, null, 10));
    try std.testing.expectEqual(@as(u8, 40), resolveWarmPercent(40, null, 80));
    try std.testing.expectEqual(@as(u8, 25), resolveWarmPercent(40, "25", 80));
    try std.testing.expectEqual(@as(u8, 0), resolveWarmPercent(40, "0", 80));
    try std.testing.expectEqual(@as(u8, 40), resolveWarmPercent(40, "90", 80));
    try std.testing.expectEqual(@as(u8, 0), resolveWarmPercent(70, null, 60));
    try std.testing.expectEqual(@as(u8, 0), resolveWarmPercent(60, null, 60));
}
