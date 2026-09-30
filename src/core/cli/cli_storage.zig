const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const cold_archive = @import("../storage/cold_archive.zig");
const compress = @import("../shared/compress.zig");
const goal = @import("../goal/goal.zig");

const Allocator = std.mem.Allocator;

pub const usage =
    "usage: di storage [stats [--json]] | compact [--older-than <d>] [--dry-run] [--no-sessions] [--no-file-index] | restore [session-id]\n";

const Mode = enum { stats, compact, restore };

const Args = struct {
    mode: Mode = .stats,
    json: bool = false,
    dry_run: bool = false,
    sessions: bool = true,
    file_index: bool = true,
    older_than_s: u64 = 7 * 86400,
    session_id: ?[]const u8 = null,
};

fn parseArgs(args: []const [:0]const u8) !Args {
    var out: Args = .{};
    var i: usize = 0;
    if (args.len > 0 and args[0].len > 0 and args[0][0] != '-') {
        out.mode = std.meta.stringToEnum(Mode, args[0]) orelse return error.InvalidArgs;
        i = 1;
    }
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            out.json = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            out.dry_run = true;
        } else if (std.mem.eql(u8, a, "--no-sessions")) {
            out.sessions = false;
        } else if (std.mem.eql(u8, a, "--no-file-index")) {
            out.file_index = false;
        } else if (std.mem.eql(u8, a, "--older-than")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            const raw: []const u8 = args[i];
            if (std.mem.eql(u8, raw, "0")) {
                out.older_than_s = 0;
            } else if (raw.len > 1 and raw[raw.len - 1] == 'd') {
                const days = std.fmt.parseInt(u64, raw[0 .. raw.len - 1], 10) catch return error.InvalidArgs;
                out.older_than_s = days * 86400;
            } else out.older_than_s = goal.parseDuration(raw) orelse return error.InvalidArgs;
        } else if (out.mode == .restore and out.session_id == null and a.len > 0 and a[0] != '-') {
            out.session_id = a;
        } else return error.InvalidArgs;
    }
    return out;
}

fn writeOut(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn mb(w: *std.Io.Writer, bytes: u64) !void {
    if (bytes >= 1 << 20) {
        try w.print("{d}.{d}M", .{ bytes >> 20, ((bytes & ((1 << 20) - 1)) * 10) >> 20 });
    } else if (bytes >= 1 << 10) {
        try w.print("{d}.{d}K", .{ bytes >> 10, ((bytes & 1023) * 10) >> 10 });
    } else try w.print("{d}B", .{bytes});
}

pub fn run(alloc: Allocator, args: []const [:0]const u8) !u8 {
    const opts = parseArgs(args) catch {
        try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), usage);
        return 1;
    };
    const home = io_mod.getenv("HOME") orelse {
        try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), "di storage: HOME is not set\n");
        return 1;
    };
    const fx_dir = try profile_paths.rootDir(alloc, home);
    defer alloc.free(fx_dir);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    switch (opts.mode) {
        .stats => {
            const s = try cold_archive.stats(alloc, fx_dir);
            if (opts.json) {
                try std.json.Stringify.value(s, .{}, w);
                try w.writeByte('\n');
            } else {
                try w.writeAll("total ");
                try mb(w, s.total_bytes);
                try w.print(" | zstd {s}\n", .{if (compress.zstdAvailable()) "libzstd" else "unavailable (deflate fallback)"});
                try w.print("sessions {d}: events ", .{s.session_count});
                try mb(w, s.events_bytes);
                try w.print(", tool-results {d} files ", .{s.tool_result_files});
                try mb(w, s.tool_result_bytes);
                try w.print(", archived {d} files ", .{s.archived_files});
                try mb(w, s.archived_bytes);
                try w.print(", command logs {d} files ", .{s.command_log_files});
                try mb(w, s.command_log_bytes);
                try w.writeAll("\nfile-index ");
                try mb(w, s.file_index_bytes);
                try w.print(" ({d} files, {d} legacy), logs ", .{ s.file_index_files, s.file_index_legacy_files });
                try mb(w, s.log_bytes);
                try w.writeAll(", other ");
                try mb(w, s.other_bytes);
                try w.print("\nduplicate tool-results: {d} files ", .{s.duplicate_result_files});
                try mb(w, s.duplicate_result_bytes);
                try w.writeByte('\n');
            }
        },
        .compact => {
            const r = try cold_archive.compact(alloc, fx_dir, .{
                .older_than_s = opts.older_than_s,
                .dry_run = opts.dry_run,
                .sessions = opts.sessions,
                .file_index = opts.file_index,
            });
            try w.print("{s}file-index ", .{if (opts.dry_run) "dry-run: " else ""});
            try mb(w, r.file_index_before);
            try w.writeAll(" -> ");
            try mb(w, r.file_index_after);
            try w.print("; sessions touched {d} (skipped live {d}); tool-results archived {d}: ", .{ r.sessions_touched, r.sessions_skipped_live, r.archived_files });
            try mb(w, r.archived_before);
            try w.writeAll(" -> ");
            try mb(w, r.archived_after);
            try w.print("; failures {d}\n", .{r.failures});
        },
        .restore => {
            const n = try cold_archive.restoreAll(alloc, fx_dir, opts.session_id);
            try w.print("restored {d} files\n", .{n});
        },
    }
    try writeOut(out.written());
    return 0;
}
