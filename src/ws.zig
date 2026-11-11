//! Just enough of WebSockets (RFC 6455) for the web terminal: the handshake,
//! reading masked client frames and writing unmasked ones.

const std = @import("std");
const sys = @import("sys.zig");

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,
};

/// The value of Sec-WebSocket-Accept for a client's Sec-WebSocket-Key.
pub fn acceptKey(key: []const u8) [28]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

pub fn handshake(fd: i32, key: []const u8) !void {
    var buf: [256]u8 = undefined;
    const accept = acceptKey(key);
    const head = try std.fmt.bufPrint(&buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{&accept});
    try sys.writeAll(fd, head);
}

pub const Frame = struct { fin: bool, opcode: Opcode, payload: []u8 };

/// The largest frame accepted; the terminal only receives keystrokes.
pub const max_payload = 1 << 20;

fn readExact(fd: i32, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try sys.read(fd, buf[got..]);
        if (n == 0) return error.Closed;
        got += n;
    }
}

/// Reads one frame into `buf`, unmasked. Clients must mask their frames.
pub fn readFrame(fd: i32, buf: []u8) !Frame {
    var head: [2]u8 = undefined;
    try readExact(fd, &head);
    return readRest(fd, head, buf);
}

fn readRest(fd: i32, head: [2]u8, buf: []u8) !Frame {
    const fin = head[0] & 0x80 != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(head[0])));
    if (head[1] & 0x80 == 0) return error.Unmasked;
    var len: u64 = head[1] & 0x7f;
    if (len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(fd, &ext);
        len = std.mem.readInt(u16, &ext, .big);
    } else if (len == 127) {
        var ext: [8]u8 = undefined;
        try readExact(fd, &ext);
        len = std.mem.readInt(u64, &ext, .big);
    }
    if (len > buf.len or len > max_payload) return error.TooLarge;
    var mask: [4]u8 = undefined;
    try readExact(fd, &mask);
    const payload = buf[0..@intCast(len)];
    try readExact(fd, payload);
    unmask(payload, mask);
    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}

fn unmask(payload: []u8, mask: [4]u8) void {
    for (payload, 0..) |*b, i| b.* ^= mask[i % 4];
}

/// The header of an unmasked server frame.
pub fn header(out: *[10]u8, opcode: Opcode, len: usize) []const u8 {
    out[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    if (len < 126) {
        out[1] = @intCast(len);
        return out[0..2];
    }
    if (len <= 0xffff) {
        out[1] = 126;
        std.mem.writeInt(u16, out[2..4], @intCast(len), .big);
        return out[0..4];
    }
    out[1] = 127;
    std.mem.writeInt(u64, out[2..10], len, .big);
    return out[0..10];
}

pub fn writeFrame(fd: i32, opcode: Opcode, payload: []const u8) !void {
    var head: [10]u8 = undefined;
    try sys.writeAll(fd, header(&head, opcode, payload.len));
    try sys.writeAll(fd, payload);
}

/// A close frame with a status code and a reason.
pub fn close(fd: i32, code: u16, reason: []const u8) void {
    var body: [125]u8 = undefined;
    std.mem.writeInt(u16, body[0..2], code, .big);
    const n = @min(reason.len, body.len - 2);
    @memcpy(body[2..][0..n], reason[0..n]);
    writeFrame(fd, .close, body[0 .. 2 + n]) catch {};
}

const t = std.testing;

test "the accept key of the RFC's example" {
    try t.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
}

test "frame headers" {
    var out: [10]u8 = undefined;
    try t.expectEqualSlices(u8, &.{ 0x82, 5 }, header(&out, .binary, 5));
    try t.expectEqualSlices(u8, &.{ 0x81, 126, 0x01, 0x00 }, header(&out, .text, 256));
    try t.expectEqual(@as(usize, 10), header(&out, .binary, 70000).len);
}

test "reading a masked frame" {
    // "Hello", masked, from RFC 6455 section 5.7.
    const wire = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    var pipe: [2]i32 = undefined;
    _ = sys.linux.pipe2(&pipe, .{ .CLOEXEC = true });
    defer sys.close(pipe[0]);
    try sys.writeAll(pipe[1], &wire);
    sys.close(pipe[1]);
    var buf: [64]u8 = undefined;
    const f = try readFrame(pipe[0], &buf);
    try t.expect(f.fin);
    try t.expectEqual(Opcode.text, f.opcode);
    try t.expectEqualStrings("Hello", f.payload);
    try t.expectError(error.Closed, readFrame(pipe[0], &buf));
}
