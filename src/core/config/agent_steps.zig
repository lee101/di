const std = @import("std");

pub const default_max_agent_steps: usize = 0;

pub fn resolveMaxAgentSteps(configured: ?usize, default_value: usize) usize {
    return configured orelse default_value;
}

pub fn parseMaxAgentSteps(raw: ?[]const u8) ?usize {
    const trimmed = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
}

pub fn resolveMaxAgentStepsWithOverride(
    configured: ?usize,
    default_value: usize,
    process_override: ?[]const u8,
) usize {
    return parseMaxAgentSteps(process_override) orelse resolveMaxAgentSteps(configured, default_value);
}

pub fn allowsStep(limit: usize, completed_steps: usize) bool {
    return limit == 0 or completed_steps < limit;
}

/// Returns a borrowed notice in buffer only near an explicit turn limit.
pub fn remaining_steps_notice(buffer: []u8, limit: usize, completed_steps: usize) ?[]const u8 {
    if (limit == 0 or completed_steps >= limit) return null;
    const remaining = limit - completed_steps;
    if (remaining > 3) return null;
    return std.fmt.bufPrint(buffer, "Turn budget: {d} model call{s} left, including this one. Prioritize required fixes and verification over optional exploration. Leave a final response when possible and report unfinished work honestly.", .{ remaining, if (remaining == 1) "" else "s" }) catch null;
}

test "remaining step notices preserve unbounded and exact cap semantics" {
    var buffer: [256]u8 = undefined;
    try std.testing.expect(remaining_steps_notice(&buffer, 0, 100) == null);
    try std.testing.expect(remaining_steps_notice(&buffer, 24, 20) == null);
    try std.testing.expect(std.mem.startsWith(u8, remaining_steps_notice(&buffer, 24, 21).?, "Turn budget: 3 model calls"));
    try std.testing.expect(std.mem.startsWith(u8, remaining_steps_notice(&buffer, 24, 23).?, "Turn budget: 1 model call"));
    try std.testing.expect(remaining_steps_notice(&buffer, 24, 24) == null);
    try std.testing.expect(remaining_steps_notice(&buffer, 24, 25) == null);
    try std.testing.expect(remaining_steps_notice(buffer[0..1], 1, 0) == null);
}

test "resolve max agent steps preserves explicit unbounded zero" {
    try std.testing.expectEqual(@as(usize, 25), resolveMaxAgentSteps(null, 25));
    try std.testing.expectEqual(@as(usize, 0), resolveMaxAgentSteps(0, 25));
    try std.testing.expectEqual(@as(usize, 50), resolveMaxAgentSteps(50, 25));
}

test "parse max agent steps accepts zero and rejects invalid input" {
    try std.testing.expectEqual(@as(usize, 0), parseMaxAgentSteps("0").?);
    try std.testing.expectEqual(@as(usize, 24), parseMaxAgentSteps("24").?);
    try std.testing.expect(parseMaxAgentSteps(null) == null);
    try std.testing.expect(parseMaxAgentSteps("") == null);
    try std.testing.expect(parseMaxAgentSteps("abc") == null);
}

test "process overrides resolve with configured and compiled defaults" {
    try std.testing.expectEqual(@as(usize, 0), resolveMaxAgentStepsWithOverride(null, default_max_agent_steps, null));
    try std.testing.expectEqual(@as(usize, 0), resolveMaxAgentStepsWithOverride(0, 24, null));
    try std.testing.expectEqual(@as(usize, 24), resolveMaxAgentStepsWithOverride(null, 0, "24"));
    try std.testing.expectEqual(@as(usize, 0), resolveMaxAgentStepsWithOverride(24, 8, "0"));
    try std.testing.expectEqual(@as(usize, 24), resolveMaxAgentStepsWithOverride(24, 8, "invalid"));
    try std.testing.expectEqual(@as(usize, 24), resolveMaxAgentStepsWithOverride(24, 8, "  \t\n"));
}

test "agent step policy treats zero as unbounded and positives as exact caps" {
    try std.testing.expect(allowsStep(0, 0));
    try std.testing.expect(allowsStep(0, 25));
    try std.testing.expect(allowsStep(2, 0));
    try std.testing.expect(allowsStep(2, 1));
    try std.testing.expect(!allowsStep(2, 2));
}
