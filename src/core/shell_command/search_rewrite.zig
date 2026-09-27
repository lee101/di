const std = @import("std");
const command_lex = @import("command_lex.zig");

/// Returns an owned command, or null when grep semantics cannot be preserved.
/// The caller must authorize rewriting and use a clean POSIX shell. The shell
/// checks availability in its own PATH and falls back only when rg is absent.
pub fn rewrite(alloc: std.mem.Allocator, command: []const u8) std.mem.Allocator.Error!?[]u8 {
    const trimmed = std.mem.trim(u8, command, " \t");
    if (trimmed.len > 8192 or !std.mem.startsWith(u8, trimmed, "grep ")) return null;
    // Reject expansion, pipelines, redirection, comments and multiline shell
    // syntax even inside quotes. This deliberately accepts a small language.
    if (std.mem.findAny(u8, trimmed, "\n\r\x00$`\\;|&<>(){}*?[]~#") != null) return null;
    var args = command_lex.tokenize_argv(alloc, trimmed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer args.deinit(alloc);
    if (args.tokens.len < 3 or !std.mem.eql(u8, args.tokens[0].raw, "grep")) return null;

    var recursive = false;
    var follow = false;
    var fixed = false;
    var text = false;
    var numbered = false;
    var filename: ?bool = null;
    var index: usize = 1;
    while (index < args.tokens.len) : (index += 1) {
        const token = args.tokens[index];
        if (std.mem.eql(u8, token.value, "--")) {
            index += 1;
            break;
        }
        if (!std.mem.startsWith(u8, token.value, "-")) break;
        if (token.value.len < 2 or token.quoted) return null;
        for (token.value[1..]) |flag| switch (flag) {
            'r' => {
                recursive = true;
                follow = false;
            },
            'R' => {
                recursive = true;
                follow = true;
            },
            'F' => fixed = true,
            'a' => text = true,
            'n' => numbered = true,
            'H' => filename = true,
            'h' => filename = false,
            else => return null,
        };
    }
    // Binary detection differs between grep and rg. Only an explicit text
    // search is eligible; do not silently change binary-file behavior.
    if (!text or index + 1 >= args.tokens.len) return null;
    const pattern = args.tokens[index];
    if (pattern.value.len == 0) return null;
    if (!fixed) {
        for (pattern.value) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != ' ') return null;
        }
    }
    const paths = args.tokens[index + 1 ..];
    for (paths) |path| {
        if (path.value.len == 0 or path.value[0] == '-') return null;
    }
    // Without recursion, rg would descend into a directory that grep rejects.
    if (!recursive or filename == null) return null;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "if command -v rg >/dev/null 2>&1; then command rg --no-config --hidden --no-ignore --text --encoding none --fixed-strings --no-heading --color never --threads 1");
    try out.appendSlice(alloc, if (numbered) " --line-number" else " --no-line-number");
    try out.appendSlice(alloc, if (filename.?) " --with-filename" else " --no-filename");
    if (follow) try out.appendSlice(alloc, " --follow");
    try out.appendSlice(alloc, " -- ");
    try out.appendSlice(alloc, pattern.raw);
    for (paths) |path| {
        try out.append(alloc, ' ');
        try out.appendSlice(alloc, path.raw);
    }
    try out.appendSlice(alloc, "; else ");
    try out.appendSlice(alloc, trimmed);
    try out.appendSlice(alloc, "; fi");
    return try out.toOwnedSlice(alloc);
}

test "search rewrite preserves text search flags and literal shell words" {
    const alloc = std.testing.allocator;
    const result = (try rewrite(alloc, "grep -RanFh 'a.b' 'source dir'")) orelse return error.TestUnexpectedResult;
    defer alloc.free(result);
    try std.testing.expect(std.mem.find(u8, result, "--line-number --no-filename --follow -- 'a.b' 'source dir'") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "; else grep -RanFh 'a.b' 'source dir'; fi"));
    const literal = (try rewrite(alloc, "grep -raH needle src")) orelse return error.TestUnexpectedResult;
    defer alloc.free(literal);
    try std.testing.expect(std.mem.find(u8, literal, "--no-line-number --with-filename -- needle src") != null);
}

test "search rewrite leaves incompatible grep and shell semantics unchanged" {
    const cases = [_][]const u8{
        "grep -rn needle src",        "grep -rIn needle src",    "grep -ranH 'a.b' src",           "grep -ra needle src",
        "grep -rac needle src",       "grep -raiq needle src",   "grep -ra needle",                "grep -anF needle src",
        "grep -ra needle -",          "grep -ra '' src",         "grep -ra needle src | head",     "grep -ra needle src > out",
        "grep -ra '$PATTERN' src",    "grep -ra needle *.zig",   "grep -ra needle src; echo done", "grep -ra needle src\necho done",
        "grep -ra 'unterminated src", "env grep -ra needle src", "echo 'grep -ra needle src'",     "grep -ra needle src # note",
    };
    for (cases) |command| try std.testing.expectEqual(@as(?[]u8, null), try rewrite(std.testing.allocator, command));
}

test "search rewrite releases allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(alloc: std.mem.Allocator) !void {
            if (try rewrite(alloc, "grep -ranFH 'needle phrase' src")) |result| alloc.free(result);
        }
    }.check, .{});
}
