//! Permission encoding for the session manager module.
//!
//! This module is deliberately isolated: `api.zig` may only import `std`,
//! `builtin`, `build_options`, or a sibling file, so it cannot reach
//! `core/shared/io.zig` for the same two helpers. Keep these in step with
//! `permissionsFromMode` and `permissionsMode` there.
//!
//! POSIX carries privacy as mode bits. Windows has none: `std.Io.File.Permissions`
//! models only the read-only attribute and access is governed by inherited
//! ACLs, so a writable entry reports `0o600` and a read-only entry `0o444`.

const std = @import("std");
const builtin = @import("builtin");

/// `FILE_ATTRIBUTE_READONLY`. The standard library's own `readOnly()` and
/// `setReadOnly()` reference a constant it does not export on Windows.
const file_attribute_readonly: u32 = 0x00000001;

pub fn fromMode(value: u32) std.Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) {
        if (value & 0o222 == 0) return @enumFromInt(file_attribute_readonly);
        return @enumFromInt(0);
    }
    return std.Io.File.Permissions.fromMode(@intCast(value));
}

pub fn mode(permissions: std.Io.File.Permissions) std.posix.mode_t {
    if (comptime builtin.os.tag == .windows) {
        const read_only = @as(u32, @intCast(@intFromEnum(permissions))) & file_attribute_readonly != 0;
        return if (read_only) 0o444 else 0o600;
    }
    return permissions.toMode();
}