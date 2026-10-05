//! Minimal Win32 surface for the Windows host.
//!
//! Zig's standard library binds almost none of the console and path APIs this
//! product needs, so the declarations live here rather than being scattered
//! across call sites. Everything in this file is Windows-only; no other module
//! may declare these externs.

const std = @import("std");

pub const BOOL = i32;
pub const DWORD = u32;
pub const WORD = u16;
pub const HANDLE = ?*anyopaque;
pub const DWORD_PTR = usize;

pub const STD_INPUT_HANDLE = @as(DWORD, -10);
pub const STD_OUTPUT_HANDLE = @as(DWORD, -11);
pub const STD_ERROR_HANDLE = @as(DWORD, -12);

/// Longest path `GetFullPathNameW` can report for a non-extended-length name.
pub const MAX_PATH_CHARS: u32 = 32767;

/// `std.Io.File.Permissions` on Windows is this attribute bitmask, but
/// `readOnly()` and `setReadOnly()` in the standard library reference a
/// constant that module does not export, so this file owns the bit.
pub const FILE_ATTRIBUTE_READONLY: DWORD = 0x00000001;

/// stdin mode flags.
pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

/// stdout mode flags.
pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
pub const ENABLE_WRAP_AT_EOL_OUTPUT: DWORD = 0x0002;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

pub const WAIT_OBJECT_0: DWORD = 0x00000000;
pub const WAIT_TIMEOUT: DWORD = 0x00000102;
pub const WAIT_FAILED: DWORD = 0xFFFFFFFF;
pub const INFINITE: DWORD = 0xFFFFFFFF;

pub const GENERIC_READ: DWORD = 0x80000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const FILE_SHARE_DELETE: DWORD = 0x00000004;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const VOLUME_NAME_DOS: DWORD = 0x0;

pub const KEY_EVENT: u32 = 0x0001;
pub const MOUSE_EVENT: u32 = 0x0002;
pub const WINDOW_BUFFER_SIZE_EVENT: u32 = 0x0004;

pub const COORD = extern struct {
    x: i16,
    y: i16,
};

pub const SMALL_RECT = extern struct {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
};

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    size: COORD,
    cursor_position: COORD,
    attributes: WORD,
    window: SMALL_RECT,
    maximum_window_size: COORD,
};

pub const INPUT_RECORD = extern union {
    key_event: KEY_EVENT_RECORD,
    mouse_event: MOUSE_EVENT_RECORD,
    window_event: WINDOW_BUFFER_SIZE_RECORD,
};

pub const KEY_EVENT_RECORD = extern struct {
    key_down: BOOL,
    repeat_count: WORD,
    virtual_key_code: WORD,
    virtual_scan_code: WORD,
    unicode_char: u16,
    control_key_state: DWORD,
};

pub const MOUSE_EVENT_RECORD = extern struct {
    mouse_position: COORD,
    button_state: DWORD,
    control_key_state: DWORD,
    event_flags: DWORD,
};

pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
    size: COORD,
};

pub extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetConsoleMode(handle: HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(handle: HANDLE, mode: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetConsoleScreenBufferInfo(
    handle: HANDLE,
    info: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(
    handle: HANDLE,
    milliseconds: DWORD,
) callconv(.winapi) DWORD;
pub extern "kernel32" fn PeekNamedPipe(
    handle: HANDLE,
    buffer: ?[*]u8,
    buffer_size: DWORD,
    bytes_read: ?*DWORD,
    bytes_available: ?*DWORD,
    bytes_left_this_message: ?*DWORD,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFullPathNameW(
    name: [*:0]const u16,
    buffer_length: DWORD,
    buffer: ?[*]u16,
    part: ?[*]u16,
) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateFileW(
    file_name: [*:0]const u16,
    desired_access: DWORD,
    share_mode: DWORD,
    security_attributes: ?*const anyopaque,
    creation_disposition: DWORD,
    flags_and_attributes: DWORD,
    template_file: HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetFinalPathNameByHandleW(
    handle: HANDLE,
    path: ?[*]u16,
    path_length: DWORD,
    flags: DWORD,
) callconv(.winapi) DWORD;
pub extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetNumberOfConsoleInputEvents(
    handle: HANDLE,
    events: *DWORD,
) callconv(.winapi) BOOL;

pub const ERROR_SUCCESS: DWORD = 0;
pub const ERROR_INSUFFICIENT_BUFFER: DWORD = 122;
pub const ERROR_INVALID_HANDLE: DWORD = 6;
pub const ERROR_BROKEN_PIPE: DWORD = 109;
pub const ERROR_NO_DATA: DWORD = 232;
pub const ERROR_MORE_DATA: DWORD = 234;
pub const ERROR_OPERATION_ABORTED: DWORD = 995;

/// Returns a handle owned by the process, or null when the standard stream is
/// not backed by the console subsystem.
pub fn stdHandle(which: DWORD) ?HANDLE {
    const handle = GetStdHandle(which) orelse return null;
    if (handle == INVALID_HANDLE_VALUE) return null;
    return handle;
}

pub fn consoleMode(handle: HANDLE) ?DWORD {
    var mode: DWORD = 0;
    if (GetConsoleMode(handle, &mode) == 0) return null;
    return mode;
}

pub fn isConsoleHandle(handle: HANDLE) bool {
    return consoleMode(handle) != null;
}

/// Returns the visible window size of a console stream.
pub fn consoleScreenBufferInfo(handle: HANDLE) ?CONSOLE_SCREEN_BUFFER_INFO {
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (GetConsoleScreenBufferInfo(handle, &info) == 0) return null;
    return info;
}

/// Switches a console input handle to character-at-a-time delivery with echo
/// and line buffering off, and VT input on so key events arrive as the escape
/// sequences the renderer already emits. Returns the mode to restore.
pub fn enterRawInputMode(handle: HANDLE) !DWORD {
    const previous = consoleMode(handle) orelse return error.NotATerminal;
    var mode = previous;
    mode &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
    mode |= ENABLE_VIRTUAL_TERMINAL_INPUT;
    if (SetConsoleMode(handle, mode) == 0) return error.ConsoleModeFailed;
    return previous;
}

pub fn restoreConsoleMode(handle: HANDLE, mode: DWORD) void {
    if (mode == 0) return;
    _ = SetConsoleMode(handle, mode);
}

pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;