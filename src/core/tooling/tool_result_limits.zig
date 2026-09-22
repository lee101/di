const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;

pub const default_max_tool_result_bytes: usize = 64 * 1024;
pub const min_configured_tool_result_bytes: usize = 1024;

pub fn resolveMaxToolResultBytes(setting: ?usize, default_value: usize) usize {
    return setting orelse default_value;
}

pub const PreparedModelOutput = struct {
    model_output: []u8,
    truncated: bool,
};

/// Returns an owned sanitized copy before any model cap.
pub fn prepareSanitizedOutput(
    alloc: Allocator,
    raw: []const u8,
) error{OutOfMemory}![]u8 {
    var scratch_impl = std.heap.ArenaAllocator.init(alloc);
    defer scratch_impl.deinit();
    const sanitized = try text_utils.sanitizeModelText(scratch_impl.allocator(), raw);
    return alloc.dupe(u8, sanitized);
}

pub fn prepareModelOutput(
    alloc: Allocator,
    tool_name: []const u8,
    raw: []const u8,
    max_bytes: usize,
) error{OutOfMemory}![]const u8 {
    return (try prepareModelOutputWithTruncation(
        alloc,
        tool_name,
        raw,
        max_bytes,
    )).model_output;
}

pub fn prepareModelOutputWithTruncation(
    alloc: Allocator,
    tool_name: []const u8,
    raw: []const u8,
    max_bytes: usize,
) error{OutOfMemory}!PreparedModelOutput {
    var scratch_impl = std.heap.ArenaAllocator.init(alloc);
    defer scratch_impl.deinit();
    const scratch = scratch_impl.allocator();

    const sanitized = try text_utils.sanitizeModelText(scratch, raw);
    const capped = try truncateTextWindowed(scratch, .{
        .text = sanitized,
        .max_bytes = max_bytes,
        .tool_name = tool_name,
        .trace_scope = "tool",
        .trace_label = tool_name,
    });
    return .{
        .model_output = try alloc.dupe(u8, capped),
        .truncated = sanitized.len > max_bytes,
    };
}

pub fn modelProjectionPreservesText(
    request_scratch: Allocator,
    raw: []const u8,
) error{OutOfMemory}!bool {
    const sanitized = try text_utils.sanitizeModelText(request_scratch, raw);
    return std.mem.eql(u8, raw, sanitized);
}

test "model projection stability rejects non-utf8 identities" {
    var scratch_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const invalid_utf8 = [_]u8{0xff};

    try std.testing.expect(try modelProjectionPreservesText(scratch, "mcp_datadog_list_incidents"));
    try std.testing.expect(!try modelProjectionPreservesText(scratch, &invalid_utf8));
}

pub const PreparedInlineResult = struct {
    model_output: []u8,
    memory: types.ToolResultMemory,
};

pub fn prepareInlineResult(
    alloc: Allocator,
    tool_name: []const u8,
    raw_output: []const u8,
    max_bytes: usize,
) error{OutOfMemory}!PreparedInlineResult {
    const prepared = try prepareModelOutputWithTruncation(
        alloc,
        tool_name,
        raw_output,
        max_bytes,
    );
    return .{
        .model_output = prepared.model_output,
        .memory = .{
            .output_handle = null,
            .preview = null,
            .output_bytes = raw_output.len,
            .stored_output_bytes = prepared.model_output.len,
            .truncated = prepared.truncated,
        },
    };
}

pub const TruncateOptions = struct {
    text: []const u8,
    max_bytes: usize,
    marker: []const u8,
    trace_scope: []const u8 = "tool",
    trace_label: []const u8 = "result",
};

pub fn truncateText(arena: std.mem.Allocator, opts: TruncateOptions) ![]const u8 {
    if (opts.text.len <= opts.max_bytes) return opts.text;

    const prefix_cap = if (opts.max_bytes > opts.marker.len)
        opts.max_bytes - opts.marker.len
    else
        0;
    const prefix_len = text_utils.utf8BackwardBoundary(opts.text, prefix_cap);

    debug_trace.logf(
        opts.trace_scope,
        "model-facing tool result truncated label={s} original_bytes={d} cap_bytes={d}",
        .{ opts.trace_label, opts.text.len, opts.max_bytes },
    );

    if (prefix_len == 0) return try arena.dupe(u8, opts.marker);
    return try std.mem.concat(arena, u8, &.{ opts.text[0..prefix_len], opts.marker });
}

pub const WindowedTruncateOptions = struct {
    text: []const u8,
    max_bytes: usize,
    tool_name: []const u8,
    trace_scope: []const u8 = "tool",
    trace_label: []const u8 = "result",
};

const legacy_marker_fmt = "\n... [tool result truncated for {s}: original {d} bytes; cap is {d} bytes]\n";
const elision_marker_fmt =
    "... [tool result truncated for {s}: total {d} bytes; shown head {d} + tail {d} bytes; middle {d} bytes ({d} lines) elided; cap is {d} bytes]";
const elision_marker_no_lines_fmt =
    "... [tool result truncated for {s}: total {d} bytes; shown head {d} + tail {d} bytes; middle {d} bytes elided; cap is {d} bytes]";

const line_align_slack: usize = 64;

const WindowedCut = struct {
    text: []const u8,
    tool_name: []const u8,
    total: usize,
    tail_start: usize,
    tail_len: usize,
    max_bytes: usize,

    fn tailAligned(self: WindowedCut) bool {
        return self.tail_start == 0 or self.tail_start == self.total or self.text[self.tail_start - 1] == '\n';
    }

    fn headAligned(self: WindowedCut, head_end: usize) bool {
        return head_end == 0 or self.text[head_end - 1] == '\n';
    }

    fn elidedLines(self: WindowedCut, head_end: usize) ?usize {
        if (!self.headAligned(head_end) or !self.tailAligned()) return null;
        const middle = self.text[head_end..self.tail_start];
        const unterminated: usize = if (middle.len > 0 and middle[middle.len - 1] != '\n') 1 else 0;
        return std.mem.count(u8, middle, "\n") + unterminated;
    }

    fn markerLen(self: WindowedCut, head_end: usize) usize {
        const elided = self.total - head_end - self.tail_len;
        return if (self.elidedLines(head_end)) |lines|
            std.fmt.count(elision_marker_fmt, .{ self.tool_name, self.total, head_end, self.tail_len, elided, lines, self.max_bytes })
        else
            std.fmt.count(elision_marker_no_lines_fmt, .{ self.tool_name, self.total, head_end, self.tail_len, elided, self.max_bytes });
    }

    fn usedBytes(self: WindowedCut, head_end: usize) usize {
        const sep: usize = if (self.headAligned(head_end)) 0 else 1;
        return head_end + sep + self.markerLen(head_end);
    }

    fn buildMarker(self: WindowedCut, arena: Allocator, head_end: usize) error{OutOfMemory}![]u8 {
        const elided = self.total - head_end - self.tail_len;
        return if (self.elidedLines(head_end)) |lines|
            std.fmt.allocPrint(arena, elision_marker_fmt, .{ self.tool_name, self.total, head_end, self.tail_len, elided, lines, self.max_bytes })
        else
            std.fmt.allocPrint(arena, elision_marker_no_lines_fmt, .{ self.tool_name, self.total, head_end, self.tail_len, elided, self.max_bytes });
    }

    /// Largest line boundary near `anchor` whose realized size still fits the cap.
    fn alignedHeadCandidate(self: WindowedCut, anchor: usize, fill_target: usize) ?usize {
        const lo = anchor -| line_align_slack;
        const hi = @min(anchor + line_align_slack, self.tail_start);
        var best: ?usize = null;
        if (lo == 0 and self.usedBytes(0) <= fill_target) best = 0;
        var search_from = lo -| 1;
        while (std.mem.indexOfScalarPos(u8, self.text, search_from, '\n')) |nl| {
            const boundary = nl + 1;
            if (boundary > hi) break;
            if (boundary >= lo and self.usedBytes(boundary) <= fill_target) {
                if (best) |current| {
                    if (boundary > current) best = boundary;
                } else best = boundary;
            }
            search_from = boundary;
        }
        return best;
    }
};

/// Head+tail windowed truncation with a self-describing middle elision marker.
/// Uses the whole byte budget (marker included) and prefers cut points at line
/// boundaries. Falls back to head-only truncateText when the marker alone
/// exceeds the budget.
fn truncateTextWindowed(arena: std.mem.Allocator, opts: WindowedTruncateOptions) error{OutOfMemory}![]const u8 {
    const text = opts.text;
    if (text.len <= opts.max_bytes) return text;

    const total = text.len;
    // Upper bound: every numeric field is <= total, and the lines field may be present.
    const marker_budget = std.fmt.count(elision_marker_fmt, .{ opts.tool_name, total, total, total, total, total, total }) + 2;
    if (marker_budget >= opts.max_bytes) return legacyWindowedFallback(arena, opts);

    const budget = opts.max_bytes - marker_budget;
    const tail_target = budget / 5;
    var tail_start = text_utils.utf8BackwardBoundary(text, total - tail_target);
    if (tail_start > 0 and text[tail_start - 1] != '\n') {
        if (std.mem.indexOfScalarPos(u8, text, tail_start, '\n')) |nl| tail_start = nl + 1;
    }
    const cut = WindowedCut{
        .text = text,
        .tool_name = opts.tool_name,
        .total = total,
        .tail_start = tail_start,
        .tail_len = total - tail_start,
        .max_bytes = opts.max_bytes,
    };

    // Solve head + separator + marker == max_bytes - 1 - tail so the marker
    // stays inside the cap and the preview uses the whole budget.
    const fill_target = opts.max_bytes - 1 - cut.tail_len;
    var head_end = text_utils.utf8BackwardBoundary(text, fill_target -| marker_budget);
    var iteration: usize = 0;
    while (iteration < 8) : (iteration += 1) {
        const used = cut.usedBytes(head_end);
        if (used == fill_target) break;
        const candidate = if (used < fill_target)
            text_utils.utf8BackwardBoundary(text, @min(head_end + (fill_target - used), cut.tail_start))
        else
            text_utils.utf8BackwardBoundary(text, head_end -| (used - fill_target));
        if (candidate == head_end) break;
        head_end = candidate;
    }
    if (cut.alignedHeadCandidate(head_end, fill_target)) |candidate| head_end = candidate;
    while (head_end > 0 and cut.usedBytes(head_end) > fill_target) {
        head_end = text_utils.utf8BackwardBoundary(text, head_end -| (cut.usedBytes(head_end) - fill_target));
    }

    const sep: []const u8 = if (cut.headAligned(head_end)) "" else "\n";
    const marker_core = try cut.buildMarker(arena, head_end);
    if (head_end + sep.len + marker_core.len + 1 + cut.tail_len > opts.max_bytes) {
        return legacyWindowedFallback(arena, opts);
    }

    debug_trace.logf(
        opts.trace_scope,
        "model-facing tool result truncated label={s} original_bytes={d} cap_bytes={d}",
        .{ opts.trace_label, total, opts.max_bytes },
    );

    return std.mem.concat(arena, u8, &.{ text[0..head_end], sep, marker_core, "\n", text[cut.tail_start..] });
}

fn legacyWindowedFallback(arena: std.mem.Allocator, opts: WindowedTruncateOptions) error{OutOfMemory}![]const u8 {
    const marker = try std.fmt.allocPrint(arena, legacy_marker_fmt, .{ opts.tool_name, opts.text.len, opts.max_bytes });
    return truncateText(arena, .{
        .text = opts.text,
        .max_bytes = opts.max_bytes,
        .marker = marker,
        .trace_scope = opts.trace_scope,
        .trace_label = opts.trace_label,
    });
}

fn markerValue(text: []const u8, key: []const u8) ?usize {
    const start = std.mem.indexOf(u8, text, key) orelse return null;
    var i = start + key.len;
    while (i < text.len and (text[i] < '0' or text[i] > '9')) : (i += 1) {}
    const digits_start = i;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
    if (i == digits_start) return null;
    return std.fmt.parseInt(usize, text[digits_start..i], 10) catch null;
}

test "prepareModelOutput preserves secret-shaped assignments verbatim" {
    const alloc = std.testing.allocator;
    const raw = "token=abcdefghijklmnopqrstuvwxyz";
    const output = try prepareModelOutput(alloc, "mcp__server__tool", raw, default_max_tool_result_bytes);
    defer alloc.free(@constCast(output));

    try std.testing.expectEqualStrings(raw, output);
}

test "prepareModelOutput preserves quoted sensitive assignments verbatim" {
    const alloc = std.testing.allocator;
    const raw = "API_KEY=\"secret-value-123456\"";
    const output = try prepareModelOutput(alloc, "run_command", raw, default_max_tool_result_bytes);
    defer alloc.free(@constCast(output));

    try std.testing.expectEqualStrings(raw, output);
}

test "prepareInlineResult preserves assignments without reclassifying lengths" {
    const alloc = std.testing.allocator;
    const raw = "AI_GATEWAY_KEY=abcdefghijklmnop";
    const prepared = try prepareInlineResult(
        alloc,
        "mcp__server__tool",
        raw,
        default_max_tool_result_bytes,
    );
    defer alloc.free(prepared.model_output);

    try std.testing.expectEqualStrings(raw, prepared.model_output);
    try std.testing.expect(!prepared.memory.truncated);
    try std.testing.expectEqual(raw.len, prepared.memory.output_bytes);
    try std.testing.expectEqual(raw.len, prepared.memory.stored_output_bytes);
}

test "prepareModelOutput caps chatty output with explicit marker" {
    const alloc = std.testing.allocator;
    const bytes = [_]u8{'x'} ** 1024;
    const output = try prepareModelOutput(alloc, "grep_files", &bytes, 512);
    defer alloc.free(@constCast(output));

    try std.testing.expect(output.len <= 512);
    try std.testing.expect(std.mem.indexOf(u8, output, "... [tool result truncated for grep_files: total 1024 bytes; shown head ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " bytes elided; cap is 512 bytes]") != null);

    const head = markerValue(output, "shown head ").?;
    const tail = markerValue(output, "+ tail ").?;
    const elided = markerValue(output, "middle ").?;
    try std.testing.expectEqual(@as(usize, bytes.len), head + tail + elided);
    try std.testing.expectEqualStrings(bytes[0..head], output[0..head]);
    try std.testing.expectEqualStrings(bytes[bytes.len - tail ..], output[output.len - tail ..]);
}

test "prepareModelOutput elides middle keeping first and last lines" {
    const alloc = std.testing.allocator;
    var buf: [800]u8 = undefined;
    for (0..50) |i| {
        _ = std.fmt.bufPrint(buf[i * 16 ..][0..16], "line-{d:0>2} padding\n", .{i}) catch unreachable;
    }
    const output = try prepareModelOutput(alloc, "grep_files", &buf, 320);
    defer alloc.free(@constCast(output));

    try std.testing.expect(output.len <= 320);
    try std.testing.expect(std.mem.indexOf(u8, output, "line-00 padding") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line-49 padding") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line-25 padding") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "... [tool result truncated for grep_files") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " lines) elided;") != null);
}

test "prepareModelOutput marker states exact byte counts" {
    const alloc = std.testing.allocator;
    var buf: [800]u8 = undefined;
    for (0..50) |i| {
        _ = std.fmt.bufPrint(buf[i * 16 ..][0..16], "line-{d:0>2} padding\n", .{i}) catch unreachable;
    }
    const output = try prepareModelOutput(alloc, "grep_files", &buf, 320);
    defer alloc.free(@constCast(output));

    const head = markerValue(output, "shown head ").?;
    const tail = markerValue(output, "+ tail ").?;
    const elided = markerValue(output, "middle ").?;
    const elided_lines = markerValue(output, " bytes (").?;
    try std.testing.expectEqual(@as(?usize, 800), markerValue(output, ": total "));
    try std.testing.expectEqual(@as(?usize, 320), markerValue(output, "cap is "));
    try std.testing.expectEqual(@as(usize, buf.len), head + tail + elided);
    try std.testing.expectEqualStrings(buf[0..head], output[0..head]);
    try std.testing.expectEqualStrings(buf[buf.len - tail ..], output[output.len - tail ..]);
    const shown_lines = std.mem.count(u8, buf[0..head], "\n") + std.mem.count(u8, buf[buf.len - tail ..], "\n");
    try std.testing.expectEqual(@as(usize, 50 - shown_lines), elided_lines);
}

test "prepareModelOutput respects the cap at the boundary" {
    const alloc = std.testing.allocator;
    const under = [_]u8{'x'} ** 299;
    const at = [_]u8{'x'} ** 300;
    const over = [_]u8{'x'} ** 301;

    const fit_under = try prepareModelOutputWithTruncation(alloc, "grep_files", &under, 300);
    defer alloc.free(fit_under.model_output);
    try std.testing.expect(!fit_under.truncated);
    try std.testing.expectEqualStrings(&under, fit_under.model_output);

    const fit_exact = try prepareModelOutputWithTruncation(alloc, "grep_files", &at, 300);
    defer alloc.free(fit_exact.model_output);
    try std.testing.expect(!fit_exact.truncated);
    try std.testing.expectEqualStrings(&at, fit_exact.model_output);

    const cut = try prepareModelOutputWithTruncation(alloc, "grep_files", &over, 300);
    defer alloc.free(cut.model_output);
    try std.testing.expect(cut.truncated);
    try std.testing.expect(cut.model_output.len <= 300);
}

test "prepareModelOutput keeps complete codepoints at the cap" {
    const alloc = std.testing.allocator;
    const single = "\xc3\xa9" ** 400;
    for ([_]usize{ 256, 257 }) |cap| {
        const output = try prepareModelOutput(alloc, "grep_files", single, cap);
        defer alloc.free(@constCast(output));
        try std.testing.expect(output.len <= cap);
        try std.testing.expect(std.unicode.utf8ValidateSlice(output));
        try std.testing.expect(std.mem.indexOf(u8, output, "... [tool result truncated for grep_files") != null);
        const head = markerValue(output, "shown head ").?;
        const tail = markerValue(output, "+ tail ").?;
        try std.testing.expectEqualStrings(single[0..head], output[0..head]);
        try std.testing.expectEqualStrings(single[single.len - tail ..], output[output.len - tail ..]);
        try std.testing.expect(std.mem.endsWith(u8, output[0..head], "\xc3\xa9"));
        try std.testing.expect(std.mem.startsWith(u8, output[output.len - tail ..], "\xc3\xa9"));
    }

    var lines: [480]u8 = undefined;
    for (0..120) |i| {
        _ = std.fmt.bufPrint(lines[i * 4 ..][0..4], "x\xc3\xa9\n", .{}) catch unreachable;
    }
    for ([_]usize{ 256, 257 }) |cap| {
        const output = try prepareModelOutput(alloc, "grep_files", &lines, cap);
        defer alloc.free(@constCast(output));
        try std.testing.expect(output.len <= cap);
        try std.testing.expect(std.unicode.utf8ValidateSlice(output));
        const head = markerValue(output, "shown head ").?;
        const tail = markerValue(output, "+ tail ").?;
        try std.testing.expectEqualStrings(lines[0..head], output[0..head]);
        try std.testing.expectEqualStrings(lines[lines.len - tail ..], output[output.len - tail ..]);
        try std.testing.expect(std.mem.endsWith(u8, output[0..head], "x\xc3\xa9\n"));
        try std.testing.expect(std.mem.startsWith(u8, output[output.len - tail ..], "x\xc3\xa9\n"));
    }
}

test "prepareModelOutput degrades to head-only marker for tiny caps" {
    const alloc = std.testing.allocator;
    const bytes = [_]u8{'x'} ** 256;

    const output = try prepareModelOutput(alloc, "grep_files", &bytes, 96);
    defer alloc.free(@constCast(output));
    const marker = "\n... [tool result truncated for grep_files: original 256 bytes; cap is 96 bytes]\n";
    try std.testing.expectEqual(@as(usize, 96), output.len);
    try std.testing.expectEqualStrings(marker, output[output.len - marker.len ..]);
    try std.testing.expect(std.mem.indexOf(u8, output, "shown head") == null);

    const bare = try prepareModelOutput(alloc, "grep_files", &bytes, 32);
    defer alloc.free(@constCast(bare));
    try std.testing.expectEqualStrings(
        "\n... [tool result truncated for grep_files: original 256 bytes; cap is 32 bytes]\n",
        bare,
    );
}
