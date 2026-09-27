//! Read-only view of the OpenAI Codex CLI login (`$CODEX_HOME/auth.json`,
//! default `~/.codex/auth.json`).
//!
//! di never writes this file. `chatgpt_oauth` adopts the session into the
//! profile store on first use, so refreshes and rotation stay inside di's own
//! credential file and `di logout codex` cannot destroy another tool's login.

const std = @import("std");
const chatgpt_session = @import("chatgpt_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("secret.zig");
const session_presence = @import("session_presence.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const auth_file_name = "auth.json";
const default_cli_dir_name = ".codex";
const codex_home_env = "CODEX_HOME";
const max_auth_file_bytes: usize = 64 * 1024;
/// Only a ChatGPT-plan login carries OAuth tokens; an `api_key` mode file holds
/// a plain API key that the subscription transport cannot use.
const chatgpt_auth_mode = "chatgpt";

pub fn presence() host.SecretStorePresence {
    if (comptime host_target.is_wasm) return .missing;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = cliDirPath(&buffer) orelse return .missing;
    return session_presence.absoluteDirFile(dir_path, auth_file_name, max_auth_file_bytes);
}

pub fn load(alloc: Allocator) !?chatgpt_session.Session {
    if (comptime host_target.is_wasm) return null;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = cliDirPath(&buffer) orelse return null;
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{ .iterate = true }) catch |err| {
        if (err != error.FileNotFound) {
            debug_trace.logf("auth", "Codex CLI session load failed step=open_dir err={s}", .{@errorName(err)});
        }
        return null;
    };
    defer dir.close(io_mod.getIo());

    var file = dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "Codex CLI session load failed step=open_file err={s}", .{@errorName(err)});
            return null;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| {
        debug_trace.logf("auth", "Codex CLI session load failed step=stat err={s}", .{@errorName(err)});
        return null;
    };
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "Codex CLI session load failed step=permissions err=InsecureAuthFile", .{});
        return null;
    }

    const bytes = io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes) catch |err| {
        debug_trace.logf("auth", "Codex CLI session load failed step=read err={s}", .{@errorName(err)});
        return null;
    };
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "Codex CLI session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

/// `$CODEX_HOME` when set, else `$HOME/.codex`. Borrows `buffer`.
fn cliDirPath(buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (io_mod.getenv(codex_home_env)) |configured| {
        const trimmed = std.mem.trim(u8, configured, " \t\r\n");
        if (trimmed.len > 0 and std.fs.path.isAbsolute(trimmed)) return trimmed;
    }
    const home = io_mod.getenv("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ home, default_cli_dir_name }) catch null;
}

/// Returns null for any file that is not a usable ChatGPT-plan login: absent
/// token fields, API-key mode, or an account id unsafe for HTTP headers.
pub fn parse(alloc: Allocator, bytes: []const u8) !?chatgpt_session.Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    if (object.get("auth_mode")) |mode| {
        if (mode != .string or !std.mem.eql(u8, mode.string, chatgpt_auth_mode)) return null;
    }
    const tokens = object.get("tokens") orelse return null;
    if (tokens != .object) return null;

    const access_text = tokenString(tokens.object, "access_token") orelse return null;
    const refresh_text = tokenString(tokens.object, "refresh_token") orelse return null;
    const account_text = tokenString(tokens.object, "account_id") orelse return null;
    if (!types.validCredentialAccountId(account_text)) return null;

    const access_token = try alloc.dupe(u8, access_text);
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try alloc.dupe(u8, refresh_text);
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const account_id = try alloc.dupe(u8, account_text);
    errdefer alloc.free(account_id);
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        // An unreadable `exp` reads as expired, so the refresh path re-mints
        // instead of trusting a token of unknown age.
        .expires_at_ms = accessTokenExpiresAtMs(alloc, access_token) catch 0,
        .account_id = account_id,
    };
}

fn tokenString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn accessTokenExpiresAtMs(alloc: Allocator, token: []const u8) !i64 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidCodexCliAccessToken;
    const payload = parts.next() orelse return error.InvalidCodexCliAccessToken;
    _ = parts.next() orelse return error.InvalidCodexCliAccessToken;
    if (parts.next() != null) return error.InvalidCodexCliAccessToken;
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch
        return error.InvalidCodexCliAccessToken;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch
        return error.InvalidCodexCliAccessToken;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, decoded, .{}) catch
        return error.InvalidCodexCliAccessToken;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexCliAccessToken;
    const exp = parsed.value.object.get("exp") orelse return error.InvalidCodexCliAccessToken;
    if (exp != .integer or exp.integer <= 0) return error.InvalidCodexCliAccessToken;
    return std.math.mul(i64, exp.integer, std.time.ms_per_s) catch
        return error.InvalidCodexCliAccessToken;
}

fn encodeJwt(alloc: Allocator, payload_json: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const size = encoder.calcSize(payload_json.len);
    const out = try alloc.alloc(u8, size);
    _ = encoder.encode(out, payload_json);
    defer alloc.free(out);
    return std.fmt.allocPrint(alloc, "header.{s}.signature", .{out});
}

test "Codex CLI login yields the subscription session and its JWT expiry" {
    const alloc = std.testing.allocator;
    const access = try encodeJwt(alloc, "{\"exp\":4102444800}");
    defer alloc.free(access);
    const bytes = try std.fmt.allocPrint(
        alloc,
        "{{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":null,\"tokens\":{{\"access_token\":\"{s}\",\"refresh_token\":\"rt.1.token\",\"account_id\":\"account-1\"}}}}",
        .{access},
    );
    defer alloc.free(bytes);

    var session = (try parse(alloc, bytes)) orelse return error.TestExpectedCodexCliSession;
    defer session.deinit(alloc);
    try std.testing.expectEqualStrings("rt.1.token", session.refresh_token);
    try std.testing.expectEqualStrings("account-1", session.account_id);
    try std.testing.expectEqual(@as(i64, 4_102_444_800_000), session.expires_at_ms);
}

test "Codex CLI login without a readable expiry is treated as expired" {
    const alloc = std.testing.allocator;
    const bytes =
        \\{"auth_mode":"chatgpt","tokens":{"access_token":"opaque-access","refresh_token":"rt.1.token","account_id":"account-1"}}
    ;
    var session = (try parse(alloc, bytes)) orelse return error.TestExpectedCodexCliSession;
    defer session.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 0), session.expires_at_ms);
    try std.testing.expect(session.expired(io_mod.milliTimestamp()));
}

test "Codex CLI login rejects API-key mode and incomplete token blocks" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "{\"auth_mode\":\"api_key\",\"OPENAI_API_KEY\":\"sk-test\",\"tokens\":{\"access_token\":\"a\",\"refresh_token\":\"r\",\"account_id\":\"account-1\"}}",
        "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":null}",
        "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"a\",\"account_id\":\"account-1\"}}",
        "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"a\",\"refresh_token\":\"r\"}}",
        "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"a\",\"refresh_token\":\"r\",\"account_id\":\"acct\\r\\ninjected\"}}",
        "[]",
    };
    for (cases) |bytes| {
        try std.testing.expect((try parse(alloc, bytes)) == null);
    }
}
