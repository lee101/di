//! Cross-platform socket primitives for the raw HTTP transport.
//!
//! `http_fetch` speaks HTTP over a socket it opens and drives itself, rather
//! than through `std.Io.net`, so it can pin one connection to one resolved
//! address. POSIX serves that from descriptors; Windows serves it from
//! WinSock2, whose handles, readiness API, and error codes all differ. This
//! module is the single place that difference is expressed.
//!
//! Errors are reported as the `Errno` semantic enum rather than a platform
//! number, so the caller's classification reads the same on both. No call here
//! retries an interrupted operation: the caller decides, because it checks for
//! cancellation between attempts.

const std = @import("std");
const builtin = @import("builtin");

pub const IpAddress = std.Io.net.IpAddress;

const is_windows = builtin.os.tag == .windows;
const posix = std.posix;

/// A live connection. A descriptor on POSIX, a `SOCKET` on Windows.
pub const Handle = if (is_windows) winsock.SOCKET else posix.fd_t;

/// A handle no live socket has, for tests and sentinels.
pub const invalid_handle: Handle = if (is_windows) winsock.INVALID_SOCKET else -1;

pub const AddressFamily = enum {
    ipv4,
    ipv6,
};

/// The failure of one socket call, named by what the caller must do about it.
pub const Errno = enum {
    /// The call would block. Retry after waiting for readiness.
    again,
    interrupted,
    connection_reset,
    broken_pipe,
    not_connected,
    network_down,
    network_unreachable,
    host_unreachable,
    connection_refused,
    system_resources,
    input_output,
    invalid_descriptor,
    /// A connect is still in flight.
    connect_in_progress,
    canceled,
    timed_out,
    address_family_unsupported,
    access_denied,
    other,
};

/// Readiness bits. Named for their meaning; the numeric values differ per
/// platform because `WSAPoll` and `poll` disagree.
pub const POLL = struct {
    /// POLLRDNORM | POLLRDBAND on Windows, the readable set `WSAPoll` accepts.
    pub const IN: u16 = if (is_windows) 0x0300 else @intCast(posix.POLL.IN);
    /// POLLWRNORM on Windows.
    pub const OUT: u16 = if (is_windows) 0x0010 else @intCast(posix.POLL.OUT);
    pub const ERR: u16 = if (is_windows) 0x0001 else @intCast(posix.POLL.ERR);
    pub const HUP: u16 = if (is_windows) 0x0002 else @intCast(posix.POLL.HUP);
    pub const NVAL: u16 = if (is_windows) 0x0004 else @intCast(posix.POLL.NVAL);
};

pub const PollFd = struct {
    handle: Handle,
    events: u16,
    revents: u16 = 0,
};

pub const PollError = error{
    Interrupted,
    SystemResources,
    NetworkDown,
    Unexpected,
};

pub const OpenError = error{
    AddressFamilyUnsupported,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketOptionFailed,
    SocketOpenFailed,
};

/// Result of one non-blocking connect, read, or write.
pub const Transfer = union(enum) {
    count: usize,
    failure: Errno,
};

pub fn open(family: AddressFamily) OpenError!Handle {
    if (comptime is_windows) return winsock.open(family);
    const native_family: posix.sa_family_t = switch (family) {
        .ipv4 => posix.AF.INET,
        .ipv6 => posix.AF.INET6,
    };
    const handle = while (true) {
        const rc = posix.system.socket(native_family, posix.SOCK.STREAM, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => break @as(posix.fd_t, @intCast(rc)),
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.SocketOpenFailed,
        }
    };
    errdefer closeSocket(handle);
    try setCloseOnExec(handle);
    try setNonBlocking(handle);
    return handle;
}

/// Windows sockets are already non-inheritable, so only POSIX needs this.
fn setCloseOnExec(handle: posix.fd_t) OpenError!void {
    while (true) switch (posix.errno(posix.system.fcntl(handle, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.SocketOptionFailed,
    };
}

fn setNonBlocking(handle: posix.fd_t) OpenError!void {
    const current = while (true) {
        const rc = posix.system.fcntl(handle, posix.F.GETFL, @as(usize, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => break rc,
            .INTR => continue,
            else => return error.SocketOptionFailed,
        }
    };
    const next: usize = @as(usize, @intCast(current)) |
        (@as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK"));
    while (true) switch (posix.errno(posix.system.fcntl(handle, posix.F.SETFL, next))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.SocketOptionFailed,
    };
}

/// Starts a connect. A non-blocking socket normally reports
/// `connect_in_progress` (or `again` on Windows); wait for `POLL.OUT`, then
/// read the outcome with `connectFailure`.
pub fn connect(handle: Handle, address: IpAddress) Transfer {
    if (comptime is_windows) return winsock.connect(handle, address);
    var storage: PosixAddress = undefined;
    const len = addressToPosix(address, &storage);
    return switch (posix.errno(posix.system.connect(handle, &storage.any, len))) {
        .SUCCESS => .{ .count = 0 },
        .AGAIN, .ALREADY, .INPROGRESS => .{ .failure = .connect_in_progress },
        else => |err| .{ .failure = errnoFromPosix(err) },
    };
}

/// The error a finished connect left on the socket, or null when it
/// succeeded. A failed lookup of that error reports `other`.
pub fn connectFailure(handle: Handle) ?Errno {
    if (comptime is_windows) return winsock.connectFailure(handle);
    var value: c_int = 0;
    var len: std.c.socklen_t = @sizeOf(c_int);
    if (std.c.getsockopt(handle, posix.SOL.SOCKET, posix.SO.ERROR, &value, &len) != 0) return .other;
    if (value == 0) return null;
    return errnoFromPosix(@enumFromInt(value));
}

pub fn sendBytes(handle: Handle, bytes: []const u8) Transfer {
    if (comptime is_windows) return winsock.sendBytes(handle, bytes);
    const rc = std.c.send(handle, bytes.ptr, bytes.len, @intCast(posix.MSG.NOSIGNAL));
    return switch (posix.errno(rc)) {
        .SUCCESS => .{ .count = @intCast(rc) },
        else => |err| .{ .failure = errnoFromPosix(err) },
    };
}

pub fn recvBytes(handle: Handle, buffer: []u8) Transfer {
    if (comptime is_windows) return winsock.recvBytes(handle, buffer);
    const rc = posix.system.read(handle, buffer.ptr, buffer.len);
    return switch (posix.errno(rc)) {
        .SUCCESS => .{ .count = @intCast(rc) },
        else => |err| .{ .failure = errnoFromPosix(err) },
    };
}

/// Waits for readiness on at most 64 sockets.
pub fn poll(fds: []PollFd, timeout_ms: i32) PollError!usize {
    if (comptime is_windows) return winsock.poll(fds, timeout_ms);
    var native: [64]posix.pollfd = undefined;
    if (fds.len > native.len) return error.SystemResources;
    for (fds, native[0..fds.len]) |fd, *slot| {
        slot.* = .{ .fd = fd.handle, .events = @bitCast(fd.events), .revents = 0 };
    }
    const count = std.math.cast(posix.nfds_t, fds.len) orelse return error.SystemResources;
    const rc = posix.system.poll(&native, count, timeout_ms);
    switch (posix.errno(rc)) {
        .SUCCESS => {
            for (fds, native[0..fds.len]) |*fd, slot| fd.revents = @bitCast(slot.revents);
            return @intCast(rc);
        },
        .INTR => return error.Interrupted,
        .NOMEM => return error.SystemResources,
        .NETDOWN => return error.NetworkDown,
        else => return error.Unexpected,
    }
}

pub fn closeSocket(handle: Handle) void {
    if (comptime is_windows) return winsock.closeSocket(handle);
    while (true) switch (posix.errno(posix.system.close(handle))) {
        .INTR => continue,
        else => return,
    };
}

fn errnoFromPosix(err: posix.E) Errno {
    return switch (err) {
        .AGAIN => .again,
        .INTR => .interrupted,
        .CONNRESET => .connection_reset,
        .PIPE => .broken_pipe,
        .NOTCONN => .not_connected,
        .NETDOWN => .network_down,
        .NETUNREACH => .network_unreachable,
        .HOSTUNREACH => .host_unreachable,
        .CONNREFUSED => .connection_refused,
        .NOBUFS, .NOMEM => .system_resources,
        .IO => .input_output,
        .BADF => .invalid_descriptor,
        .INPROGRESS, .ALREADY => .connect_in_progress,
        .CANCELED => .canceled,
        .TIMEDOUT => .timed_out,
        .AFNOSUPPORT => .address_family_unsupported,
        .ACCES, .PERM => .access_denied,
        else => .other,
    };
}

const PosixAddress = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

fn addressToPosix(address: IpAddress, storage: *PosixAddress) posix.socklen_t {
    switch (address) {
        .ip4 => |ip4| {
            storage.in = .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            };
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |ip6| {
            storage.in6 = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            return @sizeOf(posix.sockaddr.in6);
        },
    }
}

const winsock = struct {
    const SOCKET = usize;
    const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
    const SOCKET_ERROR: i32 = -1;

    const AF_INET: i32 = 2;
    const AF_INET6: i32 = 23;
    const SOCK_STREAM: i32 = 1;
    const IPPROTO_TCP: i32 = 6;
    const SOL_SOCKET: i32 = 0xFFFF;
    const SO_ERROR: i32 = 0x1007;
    const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667E));

    const WSAEINTR = 10004;
    const WSAEBADF = 10009;
    const WSAEACCES = 10013;
    const WSAEMFILE = 10024;
    const WSAEWOULDBLOCK = 10035;
    const WSAEINPROGRESS = 10036;
    const WSAEALREADY = 10037;
    const WSAENOTSOCK = 10038;
    const WSAEAFNOSUPPORT = 10047;
    const WSAENETDOWN = 10050;
    const WSAENETUNREACH = 10051;
    const WSAENETRESET = 10052;
    const WSAECONNABORTED = 10053;
    const WSAECONNRESET = 10054;
    const WSAENOBUFS = 10055;
    const WSAENOTCONN = 10057;
    const WSAESHUTDOWN = 10058;
    const WSAETIMEDOUT = 10060;
    const WSAECONNREFUSED = 10061;
    const WSAEHOSTUNREACH = 10065;
    const WSAECANCELLED = 10103;
    const WSA_E_CANCELLED = 10111;
    const WSANOTINITIALISED = 10093;

    const sockaddr = extern struct {
        family: u16,
        data: [14]u8,
    };

    const sockaddr_in = extern struct {
        family: u16 = AF_INET,
        port: u16,
        addr: [4]u8,
        zero: [8]u8 = @splat(0),
    };

    const sockaddr_in6 = extern struct {
        family: u16 = AF_INET6,
        port: u16,
        flowinfo: u32,
        addr: [16]u8,
        scope_id: u32,
    };

    const Address = extern union {
        any: sockaddr,
        in: sockaddr_in,
        in6: sockaddr_in6,
    };

    const WSAPOLLFD = extern struct {
        fd: SOCKET,
        events: i16,
        revents: i16,
    };

    /// WSADATA is 400 bytes on 32-bit and 408 on 64-bit; WSAStartup only
    /// writes it, and nothing here reads it back.
    const WsaData = extern struct { bytes: [408]u8 align(8) };

    const api = struct {
        extern "ws2_32" fn WSAStartup(version: u16, data: *WsaData) callconv(.winapi) i32;
        extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
        extern "ws2_32" fn socket(family: i32, kind: i32, protocol: i32) callconv(.winapi) SOCKET;
        extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr, len: i32) callconv(.winapi) i32;
        extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
        extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
        extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
        extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: i32, argp: *u32) callconv(.winapi) i32;
        extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, name: i32, value: [*]u8, len: *i32) callconv(.winapi) i32;
        extern "ws2_32" fn WSAPoll(fds: [*]WSAPOLLFD, count: u32, timeout: i32) callconv(.winapi) i32;
    };

    var started: std.atomic.Value(bool) = .init(false);

    /// WinSock2 must be initialised before any other call and stays up for the
    /// life of the process. WSAStartup is reference counted, so two threads
    /// racing here both succeed and the extra reference is harmless.
    fn startup() OpenError!void {
        if (started.load(.acquire)) return;
        var data: WsaData = undefined;
        // MAKEWORD(2, 2): WinSock 2.2, the version that provides WSAPoll.
        if (api.WSAStartup(0x0202, &data) != 0) return error.SocketOpenFailed;
        started.store(true, .release);
    }

    fn open(family: AddressFamily) OpenError!SOCKET {
        try startup();
        const native_family: i32 = switch (family) {
            .ipv4 => AF_INET,
            .ipv6 => AF_INET6,
        };
        const handle = api.socket(native_family, SOCK_STREAM, IPPROTO_TCP);
        if (handle == INVALID_SOCKET) return switch (api.WSAGetLastError()) {
            WSAEAFNOSUPPORT => error.AddressFamilyUnsupported,
            WSAEMFILE => error.ProcessFdQuotaExceeded,
            WSAENOBUFS => error.SystemResources,
            else => error.SocketOpenFailed,
        };
        errdefer _ = api.closesocket(handle);
        var enabled: u32 = 1;
        if (api.ioctlsocket(handle, FIONBIO, &enabled) != 0) return error.SocketOptionFailed;
        return handle;
    }

    fn connect(handle: SOCKET, address: IpAddress) Transfer {
        var storage: Address = undefined;
        const len: i32 = switch (address) {
            .ip4 => |ip4| blk: {
                storage = .{ .in = .{
                    .port = std.mem.nativeToBig(u16, ip4.port),
                    .addr = ip4.bytes,
                } };
                break :blk @sizeOf(sockaddr_in);
            },
            .ip6 => |ip6| blk: {
                storage = .{ .in6 = .{
                    .port = std.mem.nativeToBig(u16, ip6.port),
                    .flowinfo = ip6.flow,
                    .addr = ip6.bytes,
                    .scope_id = ip6.interface.index,
                } };
                break :blk @sizeOf(sockaddr_in6);
            },
        };
        if (api.connect(handle, &storage.any, len) != SOCKET_ERROR) return .{ .count = 0 };
        return switch (api.WSAGetLastError()) {
            // A non-blocking connect reports WSAEWOULDBLOCK where POSIX
            // reports EINPROGRESS.
            WSAEWOULDBLOCK, WSAEINPROGRESS, WSAEALREADY => .{ .failure = .connect_in_progress },
            else => |code| .{ .failure = errnoFromCode(code) },
        };
    }

    fn connectFailure(handle: SOCKET) ?Errno {
        var value: i32 = 0;
        var len: i32 = @sizeOf(i32);
        if (api.getsockopt(handle, SOL_SOCKET, SO_ERROR, @ptrCast(&value), &len) != 0) return .other;
        if (value == 0) return null;
        return errnoFromCode(value);
    }

    fn clampLen(len: usize) i32 {
        return @intCast(@min(len, std.math.maxInt(i32)));
    }

    fn sendBytes(handle: SOCKET, bytes: []const u8) Transfer {
        const sent = api.send(handle, bytes.ptr, clampLen(bytes.len), 0);
        if (sent == SOCKET_ERROR) return .{ .failure = errnoFromCode(api.WSAGetLastError()) };
        return .{ .count = @intCast(sent) };
    }

    fn recvBytes(handle: SOCKET, buffer: []u8) Transfer {
        const received = api.recv(handle, buffer.ptr, clampLen(buffer.len), 0);
        if (received == SOCKET_ERROR) return .{ .failure = errnoFromCode(api.WSAGetLastError()) };
        return .{ .count = @intCast(received) };
    }

    fn poll(fds: []PollFd, timeout_ms: i32) PollError!usize {
        var native: [64]WSAPOLLFD = undefined;
        if (fds.len > native.len) return error.SystemResources;
        for (fds, native[0..fds.len]) |fd, *slot| {
            slot.* = .{ .fd = fd.handle, .events = @bitCast(fd.events), .revents = 0 };
        }
        const ready = api.WSAPoll(&native, @intCast(fds.len), timeout_ms);
        if (ready == SOCKET_ERROR) return switch (api.WSAGetLastError()) {
            WSAEINTR => error.Interrupted,
            WSAENETDOWN => error.NetworkDown,
            WSAENOBUFS => error.SystemResources,
            else => error.Unexpected,
        };
        for (fds, native[0..fds.len]) |*fd, slot| fd.revents = @bitCast(slot.revents);
        return @intCast(ready);
    }

    fn closeSocket(handle: SOCKET) void {
        _ = api.closesocket(handle);
    }

    fn errnoFromCode(code: i32) Errno {
        return switch (code) {
            WSAEWOULDBLOCK => .again,
            WSAEINTR => .interrupted,
            WSAECONNRESET, WSAENETRESET => .connection_reset,
            WSAECONNABORTED => .broken_pipe,
            WSAENOTCONN, WSAESHUTDOWN => .not_connected,
            WSAENETDOWN => .network_down,
            WSAENETUNREACH => .network_unreachable,
            WSAEHOSTUNREACH => .host_unreachable,
            WSAECONNREFUSED => .connection_refused,
            WSAENOBUFS, WSAEMFILE => .system_resources,
            WSAEBADF, WSAENOTSOCK, WSANOTINITIALISED => .invalid_descriptor,
            WSAEINPROGRESS, WSAEALREADY => .connect_in_progress,
            WSAECANCELLED, WSA_E_CANCELLED => .canceled,
            WSAETIMEDOUT => .timed_out,
            WSAEAFNOSUPPORT => .address_family_unsupported,
            WSAEACCES => .access_denied,
            else => .other,
        };
    }
};

test "open starts a non-blocking loopback connect" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    // Opening and closing exercises WinSock startup and the non-blocking flag
    // on every platform without needing a listener.
    const handle = try open(.ipv4);
    defer closeSocket(handle);
    const address: IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 9 } };
    switch (connect(handle, address)) {
        .count => {},
        .failure => |err| try std.testing.expect(err == .connect_in_progress or err == .connection_refused),
    }
}
