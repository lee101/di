//! Deterministic randomized render-stress harness for inline transcript
//! rendering, modeled on a stress/oracle/reducer pattern.
//!
//! A seeded PRNG generates bounded op sequences drawn from the ANSIB subset fx
//! emits (text runs with wide/ambiguous/combining glyphs, newlines, and the SGR
//! sequences fx styles with). Each op is applied to a `resize_tests.Harness`
//! which drives `TranscriptRuntime` against the in-process `vt_emulator.Grid`
//! terminal engine (no TTY, no signals, no wall-clock timing). An oracle checks
//! rendering invariants after every op and at quiescence. A delta-debugging
//! reducer shrinks any failing (seed, op_seq) to a minimal repro, formatted as
//! an issue-ready block. The reducer is proven by a meta-test with an injected
//! failing oracle.

const std = @import("std");

const display_width = @import("../../core/shared/display_width.zig");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");
const shell_runtime = @import("../shell_runtime.zig");
const resize_tests = @import("../resize_tests.zig");

const Allocator = std.mem.Allocator;
const Harness = resize_tests.Harness;
const PhysicalHistoryProbe = resize_tests.PhysicalHistoryProbe;

// ---------------------------------------------------------------------------
// Bounded generation parameters. Tuned so the suite runs sub-second.
// ---------------------------------------------------------------------------

const stress_seed_count: usize = 24;
const stress_seed_base: u64 = 0xF00D_F00D_F00D_F00D;
const stress_seed_stride: u64 = 0x9E37_79B9_7F4A_7C15;
const max_ops_per_seed: usize = 10;
const footer_rows: u16 = 4;
const base_cols: u16 = 80;
const base_rows: u16 = 24;
const tail_keep: usize = 3;

const resize_cols = [_]u16{ 20, 32, 48, 80 };
const resize_rows = [_]u16{ 10, 16, 24 };

fn stressSeed(i: usize) u64 {
    return stress_seed_base +% (@as(u64, i) *% stress_seed_stride);
}

/// ANSIB subset fragments fx emits. Every fragment ends in a newline so the
/// tail marker always lands on its own row and cannot split across a wrap.
const fragments = [_][]const u8{
    "plain ascii run 123\n",
    "\xe7\x95\x8c\xe6\xbc\xa2\xe5\xad\x97 wide cjk\n",
    "\xf0\x9f\x98\x80\xf0\x9f\x91\x8d emoji wide\n",
    "\xc2\xb1\xc3\x97\xc2\xa7\xe2\x88\x9d ambiguous\n",
    "e\u{0301}c\u{0327}n\u{0303} combining\n",
    "line-a\nline-b\n\nline-c\n",
    "\x1b[1mbold\x1b[31mred\x1b[38;5;240mdim\x1b[0m\n",
    "\x1b[48;5;236mbg\x1b[32mgreen\x1b[0m\n",
    "\x1b[3m\xe7\x95\x8c\xc2\xb1\x1b[0m mixed e\u{0301}\n",
    "\xe2\x94\x80\xe2\x94\x82\xe2\x94\x8c\xe2\x94\x90 box\n",
    "carriage\rreturn\n",
    "\x1b[9mstrike\x1b[29m plain\n",
};
const frag_count = fragments.len;

// ---------------------------------------------------------------------------
// Op model: a small POD so sequences are trivially copyable and printable.
// ---------------------------------------------------------------------------

const OpKind = enum { text, assistant, notice, resize, scroll_pressure };

const Op = struct {
    kind: OpKind,
    atom: u8 = 0,
    a: u16 = 0,
    b: u16 = 0,
};

fn opsEql(a: []const Op, b: []const Op) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.kind != y.kind or x.atom != y.atom or x.a != y.a or x.b != y.b) return false;
    }
    return true;
}

fn genOps(seed: u64, alloc: Allocator) ![]Op {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(alloc);
    var i: usize = 0;
    while (i < max_ops_per_seed) : (i += 1) {
        const roll = r.uintLessThan(u8, 100);
        if (roll < 50) {
            try ops.append(alloc, .{ .kind = .text, .atom = r.uintLessThan(u8, frag_count) });
        } else if (roll < 65) {
            try ops.append(alloc, .{ .kind = .assistant, .atom = r.uintLessThan(u8, frag_count) });
        } else if (roll < 75) {
            try ops.append(alloc, .{ .kind = .notice, .atom = r.uintLessThan(u8, frag_count) });
        } else if (roll < 90) {
            const cols = resize_cols[r.uintLessThan(usize, resize_cols.len)];
            const rows = resize_rows[r.uintLessThan(usize, resize_rows.len)];
            try ops.append(alloc, .{ .kind = .resize, .a = cols, .b = rows });
        } else {
            try ops.append(alloc, .{ .kind = .scroll_pressure, .a = 1 + r.uintLessThan(u16, 12) });
        }
    }
    return try alloc.dupe(Op, ops.items);
}

// ---------------------------------------------------------------------------
// Oracle failure descriptor + marker tail tracker.
// ---------------------------------------------------------------------------

const Failure = struct {
    assertion: []const u8,
    detail: []const u8,
};

fn failf(assertion: []const u8, detail: []const u8) ?Failure {
    return Failure{ .assertion = assertion, .detail = detail };
}

const MarkerTail = struct {
    ids: [tail_keep]usize = undefined,
    len: usize = 0,
    next_id: usize = 0,

    fn emit(self: *MarkerTail) usize {
        const id = self.next_id;
        self.next_id += 1;
        if (self.len < tail_keep) {
            self.ids[self.len] = id;
            self.len += 1;
        } else {
            var i: usize = 1;
            while (i < tail_keep) : (i += 1) self.ids[i - 1] = self.ids[i];
            self.ids[tail_keep - 1] = id;
        }
        return id;
    }
};

// ---------------------------------------------------------------------------
// Harness driving: layout, frame capture, and op application.
// ---------------------------------------------------------------------------

fn stressLayout(cols: u16, rows: u16) types.Layout {
    std.debug.assert(rows > footer_rows);
    return .{
        .rows = rows,
        .cols = cols,
        .content_bottom = rows - footer_rows,
        .divider_top_row = rows - 3,
        .input_row = rows - 2,
        .divider_bottom_row = rows - 1,
        .hint_row = rows,
    };
}

/// Drain newly emitted frame bytes into both the assertion grid and the
/// scrollback probe, advancing the harness read offset.
fn flushAndProbe(h: *Harness, probe: *PhysicalHistoryProbe) !void {
    const total = try h.file.length(io_mod.getIo());
    if (total <= h.read_offset) return;
    const want: usize = @intCast(total - h.read_offset);
    const buf = try h.alloc.alloc(u8, want);
    defer h.alloc.free(buf);
    const n = try h.file.readPositionalAll(io_mod.getIo(), buf, h.read_offset);
    try h.vt.feed(buf[0..n]);
    try probe.feed(buf[0..n]);
    h.read_offset += n;
}

fn emitMarkerLine(h: *Harness, tail: *MarkerTail) !void {
    const id = tail.emit();
    var buf: [32]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "~{d}~\n", .{id});
    try h.shell.writeTranscript(h.alloc, &h.metrics, line, true);
}

fn applyOp(h: *Harness, tail: *MarkerTail, op: Op) !void {
    const alloc = h.alloc;
    const metrics = &h.metrics;
    switch (op.kind) {
        .text => {
            try h.shell.writeTranscript(alloc, metrics, fragments[op.atom], true);
            try emitMarkerLine(h, tail);
        },
        .assistant => {
            _ = try h.shell.streamAssistantChunk(alloc, metrics, fragments[op.atom]);
            try emitMarkerLine(h, tail);
        },
        .notice => {
            _ = try h.shell.appendSemanticNotice(alloc, .{
                .topic = "system",
                .tone = .information,
                .body = fragments[op.atom],
            });
            try emitMarkerLine(h, tail);
        },
        .resize => {
            try h.vt.resize(op.a, op.b);
            try shell_runtime.applyResizeWithLayout(&h.shell, metrics, stressLayout(op.a, op.b), true);
        },
        .scroll_pressure => {
            var k: u16 = 0;
            while (k < op.a) : (k += 1) try emitMarkerLine(h, tail);
        },
    }
}

fn renderSettle(h: *Harness, probe: *PhysicalHistoryProbe) !void {
    try h.renderTranscriptFrame();
    try flushAndProbe(h, probe);
}

// ---------------------------------------------------------------------------
// Oracle invariants. Derived from existing resize/VT tests; see notes.
// ---------------------------------------------------------------------------

fn snapshotGrid(h: *Harness) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(h.alloc);
    try h.vt.snapshot(&out);
    return try h.alloc.dupe(u8, out.items);
}

/// grid row display widths are bounded by the current cols.
fn checkWidthBounded(h: *Harness) ?Failure {
    const cols: usize = h.vt.cols;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        h.vt.rowTextTrimmed(row, &buf) catch return failf("width_bounded", "row read");
        if (display_width.visibleWidthIgnoringAnsi(buf.items) > cols) {
            return failf("width_bounded", "grid row exceeds cols");
        }
    }
    return null;
}

fn gridContains(h: *Harness, needle: []const u8) bool {
    const bottom = h.shell.layout.content_bottom;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    var row: u16 = 1;
    while (row <= bottom) : (row += 1) {
        buf.clearRetainingCapacity();
        h.vt.rowText(row, &buf) catch return false;
        if (std.mem.find(u8, buf.items, needle) != null) return true;
    }
    return false;
}

/// The tail of emitted text (the most recent marker) is visible above the fold.
/// Older text may legitimately scroll into history when the viewport overflows,
/// so only the most recent tail is required to remain visible in the fold.
fn checkTailVisible(h: *Harness, tail: *const MarkerTail) ?Failure {
    if (tail.len == 0) return null;
    var mbuf: [32]u8 = undefined;
    const marker = std.fmt.bufPrint(&mbuf, "~{d}~", .{tail.ids[tail.len - 1]}) catch
        return failf("tail_visible", "marker format");
    if (!gridContains(h, marker)) return failf("tail_visible", "tail marker not visible");
    return null;
}

/// Re-rendering at the same size is byte-stable (idempotence) and does not
/// clobber scrollback (the probe history is not evicted by rendering).
fn checkIdempotent(h: *Harness, probe: *PhysicalHistoryProbe) ?Failure {
    const alloc = h.alloc;
    const grid_before = snapshotGrid(h) catch return failf("idempotent", "snapshot");
    defer alloc.free(grid_before);
    const hist_before = alloc.dupe(u8, probe.history.items) catch
        return failf("scrollback_preserved", "history dupe");
    defer alloc.free(hist_before);

    h.renderTranscriptFrame() catch return failf("idempotent", "re-render");
    flushAndProbe(h, probe) catch return failf("idempotent", "re-flush");

    const grid_after = snapshotGrid(h) catch return failf("idempotent", "snapshot");
    defer alloc.free(grid_after);
    if (!std.mem.eql(u8, grid_before, grid_after)) {
        return failf("idempotent", "grid not byte-stable across re-render");
    }
    if (!std.mem.eql(u8, hist_before, probe.history.items)) {
        return failf("scrollback_preserved", "render evicted scrollback");
    }
    return null;
}

fn checkInvariants(h: *Harness, probe: *PhysicalHistoryProbe, tail: *const MarkerTail) ?Failure {
    if (checkWidthBounded(h)) |f| return f;
    if (checkTailVisible(h, tail)) |f| return f;
    return checkIdempotent(h, probe);
}

// ---------------------------------------------------------------------------
// Sequence replay: the oracle entry point shared by stress and reduction.
// ---------------------------------------------------------------------------

fn runSequence(alloc: Allocator, ops: []const Op) ?Failure {
    var h = Harness.init(alloc, base_cols, base_rows, footer_rows) catch
        return failf("no_error", "harness init");
    defer h.deinit();
    var probe = PhysicalHistoryProbe.init(base_cols, base_rows) catch
        return failf("no_error", "probe init");
    defer probe.deinit();
    h.shell.initViewport(&h.metrics, 1) catch return failf("no_error", "viewport init");

    var tail: MarkerTail = .{};
    for (ops) |op| {
        applyOp(&h, &tail, op) catch return failf("no_error", "op apply");
        renderSettle(&h, &probe) catch return failf("no_error", "render");
        if (checkInvariants(&h, &probe, &tail)) |f| return f;
    }
    renderSettle(&h, &probe) catch return failf("no_error", "quiescence render");
    return checkInvariants(&h, &probe, &tail);
}

const RealOracleCtx = struct { alloc: Allocator };

fn realOracle(ctx: RealOracleCtx, ops: []const Op) ?Failure {
    return runSequence(ctx.alloc, ops);
}

// ---------------------------------------------------------------------------
// Reducer: iterative op-deletion delta debugging to a 1-minimal failure.
// ---------------------------------------------------------------------------

fn reduceMinimal(
    comptime T: type,
    alloc: Allocator,
    ops: []const T,
    ctx: anytype,
    oracle_fn: anytype,
) ![]T {
    var cur = try alloc.dupe(T, ops);
    errdefer alloc.free(cur);
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < cur.len) {
            const cand = try alloc.alloc(T, cur.len - 1);
            defer alloc.free(cand);
            @memcpy(cand[0..i], cur[0..i]);
            @memcpy(cand[i..], cur[i + 1 ..]);
            if (oracle_fn(ctx, cand) != null) {
                const next = try alloc.dupe(T, cand);
                alloc.free(cur);
                cur = next;
                changed = true;
            } else {
                i += 1;
            }
        }
    }
    return cur;
}

fn formatRepro(
    comptime T: type,
    alloc: Allocator,
    seed: u64,
    ops: []const T,
    assertion: []const u8,
    comptime fmt_op: anytype,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("render-stress failure repro\n");
    try out.writer.print("seed: 0x{x}\n", .{seed});
    try out.writer.print("assertion: {s}\n", .{assertion});
    try out.writer.print("minimal ops ({d}):\n", .{ops.len});
    for (ops, 0..) |op, i| {
        const s = try fmt_op(alloc, op);
        defer alloc.free(s);
        try out.writer.print("  [{d}] {s}\n", .{ i, s });
    }
    return out.toOwnedSlice();
}

fn fmtOpRepro(alloc: Allocator, op: Op) ![]u8 {
    return switch (op.kind) {
        .text => std.fmt.allocPrint(alloc, "text atom={d}", .{op.atom}),
        .assistant => std.fmt.allocPrint(alloc, "assistant atom={d}", .{op.atom}),
        .notice => std.fmt.allocPrint(alloc, "notice atom={d}", .{op.atom}),
        .resize => std.fmt.allocPrint(alloc, "resize {d}x{d}", .{ op.a, op.b }),
        .scroll_pressure => std.fmt.allocPrint(alloc, "scroll_pressure {d}", .{op.a}),
    };
}

// ---------------------------------------------------------------------------
// Meta-test scaffolding: a tiny injected oracle that fails only when a poison
// op is present, proving the reducer isolates the single offending op.
// ---------------------------------------------------------------------------

const MetaOp = enum { alpha, beta, poison, gamma, delta };
const MetaCtx = struct {};

fn metaOracle(_: MetaCtx, ops: []const MetaOp) ?Failure {
    for (ops) |op| if (op == .poison) return failf("meta_injected", "poison present");
    return null;
}

fn fmtMetaOpRepro(alloc: Allocator, op: MetaOp) ![]u8 {
    return alloc.dupe(u8, @tagName(op));
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "render stress op generation is deterministic per seed" {
    const alloc = std.testing.allocator;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const seed = stressSeed(i);
        const a = try genOps(seed, alloc);
        defer alloc.free(a);
        const b = try genOps(seed, alloc);
        defer alloc.free(b);
        try std.testing.expect(opsEql(a, b));
    }
}

test "render stress reducer shrinks an injected failing case to the single offending op" {
    const alloc = std.testing.allocator;
    const seq = [_]MetaOp{ .alpha, .beta, .poison, .gamma, .delta };
    const ctx = MetaCtx{};

    // The injected oracle fails on the known sequence (it contains the poison).
    try std.testing.expect(metaOracle(ctx, &seq) != null);

    const minimal = try reduceMinimal(MetaOp, alloc, &seq, ctx, metaOracle);
    defer alloc.free(minimal);
    try std.testing.expectEqual(@as(usize, 1), minimal.len);
    try std.testing.expectEqual(MetaOp.poison, minimal[0]);

    // The reduced case formats as an issue-ready repro block.
    const repro = try formatRepro(MetaOp, alloc, 0x2A, minimal, "meta_injected", fmtMetaOpRepro);
    defer alloc.free(repro);
    try std.testing.expect(std.mem.find(u8, repro, "seed: 0x") != null);
    try std.testing.expect(std.mem.find(u8, repro, "assertion: meta_injected") != null);
    try std.testing.expect(std.mem.find(u8, repro, "poison") != null);
}

test "render stress randomized sequences satisfy the oracle" {
    const alloc = std.testing.allocator;
    var i: usize = 0;
    while (i < stress_seed_count) : (i += 1) {
        const seed = stressSeed(i);
        const ops = try genOps(seed, alloc);
        defer alloc.free(ops);
        if (runSequence(alloc, ops)) |failure| {
            const ctx = RealOracleCtx{ .alloc = alloc };
            const minimal = try reduceMinimal(Op, alloc, ops, ctx, realOracle);
            defer alloc.free(minimal);
            const min_fail = realOracle(ctx, minimal) orelse failure;
            const repro = try formatRepro(Op, alloc, seed, minimal, min_fail.assertion, fmtOpRepro);
            defer alloc.free(repro);
            std.debug.print("\n{s}\n", .{repro});
            return error.RenderStressOracleFailure;
        }
    }
}
