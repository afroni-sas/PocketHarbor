//! TCP helpers on the loopback, and the probes that decide if a service is up.

const std = @import("std");
const sys = @import("sys.zig");
const linux = sys.linux;

pub const Addr = struct { ip: [4]u8, port: u16 };

pub fn parseAddr(s: []const u8) !Addr {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return .{
        .ip = .{ 0, 0, 0, 0 },
        .port = try std.fmt.parseInt(u16, s, 10),
    };
    var ip: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s[0..colon], '.');
    for (&ip) |*b| b.* = try std.fmt.parseInt(u8, it.next() orelse return error.BadAddress, 10);
    if (it.next() != null) return error.BadAddress;
    return .{ .ip = ip, .port = try std.fmt.parseInt(u16, s[colon + 1 ..], 10) };
}

pub fn listenTcp(addr: Addr) sys.Err!i32 {
    const flags = linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
    const fd: i32 = @intCast(try sys.ck(linux.socket(linux.AF.INET, flags, 0)));
    errdefer sys.close(fd);
    const one: u32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
    var sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, addr.port), .addr = @bitCast(addr.ip) };
    _ = try sys.ck(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
    _ = try sys.ck(linux.listen(fd, 1024));
    return fd;
}

/// The port a socket is bound to, such as the one the kernel picked for 0.
pub fn localPort(fd: i32) !u16 {
    var sa: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = try sys.ck(linux.getsockname(fd, @ptrCast(&sa), &len));
    return std.mem.bigToNative(u16, sa.port);
}

/// The address this device uses on its network, the one a LAN DNS record
/// points at. A UDP socket is "connected" to pick a route: nothing is sent.
pub fn lanAddress() ?[4]u8 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer sys.close(fd);
    var to: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, 53), .addr = @bitCast([4]u8{ 1, 1, 1, 1 }) };
    if (linux.errno(linux.connect(fd, @ptrCast(&to), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return null;
    var sa: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&sa), &len)) != .SUCCESS) return null;
    const ip: [4]u8 = @bitCast(sa.addr);
    if (ip[0] == 0 or ip[0] == 127) return null;
    return ip;
}

pub fn loopback(port: u16) linux.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
}

fn waitFor(fd: i32, events: i16, timeout_ms: i32) bool {
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    const rc = linux.poll(&pfd, 1, timeout_ms);
    return linux.errno(rc) == .SUCCESS and rc > 0;
}

fn connectLoopback(port: u16, timeout_ms: i32) ?i32 {
    const flags = linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
    const rc = linux.socket(linux.AF.INET, flags, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    var sa = loopback(port);
    const e = linux.errno(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
    if (e == .SUCCESS) return fd;
    if (e == .INPROGRESS and waitFor(fd, linux.POLL.OUT, timeout_ms) and socketError(fd) == 0) return fd;
    sys.close(fd);
    return null;
}

pub fn socketError(fd: i32) u32 {
    var err: u32 = 1;
    var len: linux.socklen_t = 4;
    _ = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&err), &len);
    return err;
}

/// True once something accepts connections on `port`.
pub fn tcpProbe(port: u16, timeout_ms: i32) bool {
    const fd = connectLoopback(port, timeout_ms) orelse return false;
    sys.close(fd);
    return true;
}

/// The status of `GET path`, or null if nothing valid came back.
pub fn httpStatus(port: u16, path: []const u8, timeout_ms: i32) ?u16 {
    const fd = connectLoopback(port, timeout_ms) orelse return null;
    defer sys.close(fd);
    var req_buf: [1024]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: localhost\r\nUser-Agent: pocketharbor-health\r\nConnection: close\r\n\r\n", .{path}) catch return null;
    if (!waitFor(fd, linux.POLL.OUT, timeout_ms)) return null;
    if (linux.errno(linux.write(fd, req.ptr, req.len)) != .SUCCESS) return null;
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    while (got < 12) {
        if (!waitFor(fd, linux.POLL.IN, timeout_ms)) return null;
        const n = linux.read(fd, buf[got..].ptr, buf.len - got);
        if (linux.errno(n) != .SUCCESS or n == 0) return null;
        got += n;
    }
    if (!std.mem.startsWith(u8, &buf, "HTTP/1.")) return null;
    const code = std.fmt.parseInt(u16, buf[9..12], 10) catch return null;
    // Hanging up on a response still being sent shows up as an error in the
    // app's own logs, so let it finish.
    var total: usize = 0;
    while (total < 1 << 20 and waitFor(fd, linux.POLL.IN, 200)) {
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        total += n;
    }
    return code;
}
