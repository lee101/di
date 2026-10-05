//! Corrects a Zig 0.16 standard-library defect on Windows.
//!
//! `Dir.openFile` with `follow_symlinks = false` opens the handle for
//! asynchronous I/O (it must, to open the reparse point itself), but returns a
//! `File` marked blocking. The blocking read and write paths treat a pending
//! result as unreachable, so the first read of such a file panics. This adapter
//! marks those handles nonblocking, which routes them through the paths that
//! wait for completion. Every other call passes straight through.

const std = @import("std");

var wrapped_vtable: std.Io.VTable = undefined;
var wrapped_original_vtable: ?*const std.Io.VTable = null;

pub fn wrap(original: std.Io) std.Io {
    if (wrapped_original_vtable) |original_vtable| {
        std.debug.assert(original_vtable == original.vtable);
    } else {
        wrapped_vtable = original.vtable.*;
        wrapped_vtable.dirOpenFile = dirOpenFile;
        wrapped_original_vtable = original.vtable;
    }
    return .{
        .userdata = original.userdata,
        .vtable = &wrapped_vtable,
    };
}

fn dirOpenFile(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    sub_path: []const u8,
    options: std.Io.Dir.OpenFileOptions,
) std.Io.File.OpenError!std.Io.File {
    var file = try wrapped_original_vtable.?.dirOpenFile(userdata, dir, sub_path, options);
    if (!options.follow_symlinks) file.flags.nonblocking = true;
    return file;
}
