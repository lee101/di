const std = @import("std");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");

pub const env_name = "FX_PROMPT_CACHE_TTL";
const max_message_breakpoints = 2;

pub const Ttl = enum(u8) {
    five_minutes,
    one_hour,

    pub fn parse(text: []const u8) ?Ttl {
        if (std.mem.eql(u8, text, "5m")) return .five_minutes;
        if (std.mem.eql(u8, text, "1h")) return .one_hour;
        return null;
    }

    pub fn label(self: Ttl) []const u8 {
        return switch (self) {
            .five_minutes => "5m",
            .one_hour => "1h",
        };
    }
};

var configured = std.atomic.Value(u8).init(@intFromEnum(Ttl.five_minutes));

pub fn setConfigured(ttl: Ttl) void {
    configured.store(@intFromEnum(ttl), .monotonic);
}

pub fn effectiveTtl() Ttl {
    if (io_mod.getenv(env_name)) |value| {
        if (Ttl.parse(value)) |ttl| return ttl;
    }
    return @enumFromInt(configured.load(.monotonic));
}

pub fn supportsCacheControl(model: []const u8) bool {
    if (std.mem.startsWith(u8, model, "anthropic/")) return true;
    const needle = "claude";
    if (model.len < needle.len) return false;
    var start: usize = 0;
    while (start + needle.len <= model.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(model[start..][0..needle.len], needle)) return true;
    }
    return false;
}

pub fn validSessionHeader(session_id: ?[]const u8) ?[]const u8 {
    const id = session_id orelse return null;
    if (id.len == 0 or id.len > 256) return null;
    for (id) |byte| if (byte <= 0x20 or byte >= 0x7f) return null;
    return id;
}

pub const Plan = struct {
    ttl: ?Ttl = null,
    system_index: ?usize = null,
    message_indexes: [max_message_breakpoints]?usize = @splat(null),

    pub fn marksSystem(self: Plan, index: usize) ?Ttl {
        const ttl = self.ttl orelse return null;
        return if (self.system_index == index) ttl else null;
    }

    pub fn marksMessage(self: Plan, index: usize) ?Ttl {
        const ttl = self.ttl orelse return null;
        for (self.message_indexes) |candidate| if (candidate == index) return ttl;
        return null;
    }
};

fn hasText(message: types.ChatMessage) bool {
    const text = message.content orelse return false;
    return text.len != 0;
}

pub fn plan(
    model: []const u8,
    enabled: bool,
    ttl: Ttl,
    instructions: []const types.ChatMessage,
    messages: []const types.ChatMessage,
) Plan {
    if (!enabled or !supportsCacheControl(model)) return .{};
    var result: Plan = .{ .ttl = ttl };
    var index = instructions.len;
    while (index > 0) {
        index -= 1;
        if (hasText(instructions[index])) {
            result.system_index = index;
            break;
        }
    }
    var found: usize = 0;
    index = messages.len;
    while (index > 0 and found < max_message_breakpoints) {
        index -= 1;
        const message = messages[index];
        if (message.role != .user and message.role != .tool) continue;
        if (!hasText(message)) continue;
        result.message_indexes[found] = index;
        found += 1;
    }
    return result;
}

pub fn writeControl(writer: *std.Io.Writer, ttl: Ttl) !void {
    try writer.writeAll("\"cache_control\":{\"type\":\"ephemeral\"");
    if (ttl == .one_hour) try writer.writeAll(",\"ttl\":\"1h\"");
    try writer.writeByte('}');
}

pub fn writeCachedTextContent(writer: *std.Io.Writer, text: []const u8, ttl: Ttl) !void {
    try writer.writeAll("[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeByte(',');
    try writeControl(writer, ttl);
    try writer.writeAll("}]");
}

test "prompt cache policy: ttl parses only the supported labels" {
    try std.testing.expectEqual(Ttl.five_minutes, Ttl.parse("5m").?);
    try std.testing.expectEqual(Ttl.one_hour, Ttl.parse("1h").?);
    try std.testing.expect(Ttl.parse("10m") == null);
    try std.testing.expect(Ttl.parse("") == null);
    try std.testing.expectEqualStrings("1h", Ttl.one_hour.label());
}

test "prompt cache policy: cache control applies to anthropic family model ids only" {
    for ([_][]const u8{ "anthropic/claude-sonnet-4.5", "or/claude-opus-4", "vendor/Claude-3-haiku", "claude-sonnet-5" }) |model| {
        try std.testing.expect(supportsCacheControl(model));
    }
    for ([_][]const u8{ "openai/gpt-5", "google/gemini-2.5-pro", "xiaomi/mimo-v2.6-pro", "" }) |model| {
        try std.testing.expect(!supportsCacheControl(model));
    }
}

test "prompt cache policy: session header rejects empty oversized and non printable ids" {
    try std.testing.expectEqualStrings("abc-123", validSessionHeader("abc-123").?);
    try std.testing.expect(validSessionHeader(null) == null);
    try std.testing.expect(validSessionHeader("") == null);
    try std.testing.expect(validSessionHeader("a b") == null);
    try std.testing.expect(validSessionHeader("a\nb") == null);
    try std.testing.expect(validSessionHeader("a" ** 257) == null);
}

test "prompt cache policy: plan marks the last system part and the last two user or tool messages" {
    const instructions = [_]types.ChatMessage{
        .{ .role = .system, .content = "first" },
        .{ .role = .system, .content = "last" },
        .{ .role = .system, .content = "" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "u0" },
        .{ .role = .assistant, .content = "a0" },
        .{ .role = .user, .content = "u1" },
        .{ .role = .assistant, .content = "a1" },
        .{ .role = .tool, .content = "t1", .tool_call_id = "c" },
    };
    const result = plan("anthropic/claude-sonnet-4.5", true, .one_hour, &instructions, &messages);
    try std.testing.expectEqual(Ttl.one_hour, result.marksSystem(1).?);
    try std.testing.expect(result.marksSystem(0) == null);
    try std.testing.expect(result.marksMessage(4) != null);
    try std.testing.expect(result.marksMessage(2) != null);
    try std.testing.expect(result.marksMessage(0) == null);
    try std.testing.expect(result.marksMessage(1) == null);
}

test "prompt cache policy: plan is empty when disabled or for other model families" {
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "s" }};
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "u" }};
    const disabled = plan("anthropic/claude-sonnet-4.5", false, .five_minutes, &instructions, &messages);
    try std.testing.expect(disabled.marksSystem(0) == null and disabled.marksMessage(0) == null);
    const other = plan("openai/gpt-5", true, .five_minutes, &instructions, &messages);
    try std.testing.expect(other.marksSystem(0) == null and other.marksMessage(0) == null);
}

test "prompt cache policy: control serialization adds ttl only for one hour" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCachedTextContent(&out.writer, "hi \"x\"", .five_minutes);
    try std.testing.expectEqualStrings(
        "[{\"type\":\"text\",\"text\":\"hi \\\"x\\\"\",\"cache_control\":{\"type\":\"ephemeral\"}}]",
        out.written(),
    );
    out.clearRetainingCapacity();
    try writeControl(&out.writer, .one_hour);
    try std.testing.expectEqualStrings("\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}", out.written());
}
