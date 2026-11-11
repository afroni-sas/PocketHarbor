//! A small blocking HTTP server for the panel and its API: one thread per
//! connection, one request per connection. It sits behind the proxy, which
//! already does the hard parts of facing the network.

const std = @import("std");
const sys = @import("sys.zig");
const http = @import("http.zig");
const net = @import("net.zig");
const linux = sys.linux;
const Allocator = std.mem.Allocator;

pub const max_body = 4 * 1024 * 1024;

pub const Request = struct {
    a: Allocator,
    fd: i32,
    method: []const u8,
    /// Without the query string.
    path: []const u8,
    query: []const u8,
    head: []const u8,
    body: []const u8,
    peer: [4]u8,

    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }

    pub fn cookie(self: *const Request, name: []const u8) ?[]const u8 {
        const all = self.header("cookie") orelse return null;
        var it = std.mem.splitScalar(u8, all, ';');
        while (it.next()) |part| {
            const kv = std.mem.trim(u8, part, " ");
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
        }
        return null;
    }

    pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.query, '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
        }
        return null;
    }

    /// A query parameter with %XX and + decoded, for free text.
    pub fn text(self: *const Request, name: []const u8) ?[]const u8 {
        const raw = self.param(name) orelse return null;
        return decodeQuery(self.a, raw) catch null;
    }

    /// The client's address. Behind the local proxy, the one it reports.
    pub fn clientIp(self: *const Request) []const u8 {
        if (self.peer[0] == 127) {
            if (self.header("x-forwarded-for")) |xff| {
                const first = std.mem.indexOfScalar(u8, xff, ',') orelse xff.len;
                return std.mem.trim(u8, xff[0..first], " ");
            }
        }
        return std.fmt.allocPrint(self.a, "{d}.{d}.{d}.{d}", .{ self.peer[0], self.peer[1], self.peer[2], self.peer[3] }) catch "";
    }

    pub fn secure(self: *const Request) bool {
        const proto = self.header("x-forwarded-proto") orelse return false;
        return self.peer[0] == 127 and std.mem.eql(u8, proto, "https");
    }

    pub fn json(self: *const Request, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.a, self.body, .{ .ignore_unknown_fields = true });
    }
};

pub const Response = struct {
    a: Allocator,
    fd: i32,
    sent: bool = false,
    status: u16 = 0,
    headers: std.ArrayList(u8) = .empty,

    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) void {
        self.headers.print(self.a, "{s}: {s}\r\n", .{ name, value }) catch {};
    }

    pub fn send(self: *Response, status: u16, content_type: []const u8, body: []const u8) void {
        if (self.sent) return;
        self.sent = true;
        self.status = status;
        var head: std.ArrayList(u8) = .empty;
        head.print(self.a, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n" ++
            "X-Content-Type-Options: nosniff\r\nReferrer-Policy: same-origin\r\nX-Frame-Options: DENY\r\n", .{
            status, reasonOf(status), content_type, body.len,
        }) catch return;
        head.appendSlice(self.a, self.headers.items) catch return;
        head.appendSlice(self.a, "\r\n") catch return;
        sys.writeAll(self.fd, head.items) catch return;
        sys.writeAll(self.fd, body) catch {};
    }

    pub fn json(self: *Response, status: u16, value: anytype) void {
        const body = std.json.Stringify.valueAlloc(self.a, value, .{}) catch return self.send(500, "text/plain", "out of memory");
        self.addHeader("Cache-Control", "no-store");
        self.send(status, "application/json", body);
    }

    pub fn fail(self: *Response, status: u16, message: []const u8) void {
        self.json(status, .{ .@"error" = message });
    }

    /// Takes over the socket, for streams and WebSockets.
    pub fn hijack(self: *Response) i32 {
        self.sent = true;
        return self.fd;
    }
};

fn reasonOf(status: u16) []const u8 {
    return switch (status) {
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        429 => "Too Many Requests",
        else => if (status >= 500) "Internal Server Error" else "OK",
    };
}

pub const Handler = *const fn (ctx: *anyopaque, req: *Request, res: *Response) void;

fn setTimeout(fd: i32, seconds: i64) void {
    const tv = [2]i64{ seconds, 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(@TypeOf(tv)));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(@TypeOf(tv)));
}

fn readRequest(a: Allocator, fd: i32, peer: [4]u8) !Request {
    var head_buf = try a.alloc(u8, http.max_head);
    var len: usize = 0;
    const end = while (true) {
        if (http.headEnd(head_buf[0..len])) |e| break e;
        if (len == head_buf.len) return error.HeadTooLarge;
        const n = try sys.read(fd, head_buf[len..]);
        if (n == 0) return error.Closed;
        len += n;
    };
    const head = head_buf[0..end];
    const eol = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, head[0..eol], ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    if (target.len == 0 or target[0] != '/') return error.BadRequest;
    const q = std.mem.indexOfScalar(u8, target, '?');

    var req: Request = .{
        .a = a,
        .fd = fd,
        .method = method,
        .path = target[0 .. q orelse target.len],
        .query = if (q) |i| target[i + 1 ..] else "",
        .head = head,
        .body = "",
        .peer = peer,
    };
    if (req.header("transfer-encoding") != null) return error.LengthRequired;
    const length = std.fmt.parseInt(usize, req.header("content-length") orelse "0", 10) catch return error.BadRequest;
    if (length > max_body) return error.TooLarge;
    const body = try a.alloc(u8, length);
    const already = len - end;
    const take = @min(already, length);
    @memcpy(body[0..take], head_buf[end..][0..take]);
    var got = take;
    while (got < length) {
        const n = try sys.read(fd, body[got..]);
        if (n == 0) return error.Closed;
        got += n;
    }
    req.body = body;
    return req;
}

const Job = struct { fd: i32, peer: [4]u8, handler: Handler, ctx: *anyopaque };

fn serveOne(job: Job) void {
    defer sys.close(job.fd);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    setTimeout(job.fd, 20);
    var res: Response = .{ .a = a, .fd = job.fd };
    var req = readRequest(a, job.fd, job.peer) catch |e| {
        switch (e) {
            error.Closed => {},
            error.TooLarge => res.fail(413, "request body too large"),
            error.LengthRequired => res.fail(411, "send a Content-Length"),
            else => res.fail(400, "bad request"),
        }
        return;
    };
    job.handler(job.ctx, &req, &res);
    if (!res.sent) res.fail(500, "no response");
}

pub fn serve(addr: net.Addr, handler: Handler, ctx: *anyopaque) !void {
    return serveOn(try net.listenTcp(addr), handler, ctx);
}

/// Serves on a socket that is already listening.
pub fn serveOn(listener: i32, handler: Handler, ctx: *anyopaque) !void {
    // Blocking accepts suit a thread per connection.
    _ = linux.fcntl(listener, linux.F.SETFL, 0);
    while (true) {
        var sa: linux.sockaddr.in = undefined;
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        const rc = linux.accept4(listener, @ptrCast(&sa), &len, linux.SOCK.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) {
            sys.sleepMs(10);
            continue;
        }
        const job: Job = .{ .fd = @intCast(rc), .peer = @bitCast(sa.addr), .handler = handler, .ctx = ctx };
        const thread = std.Thread.spawn(.{ .stack_size = 1 << 20 }, serveOne, .{job}) catch {
            sys.close(job.fd);
            continue;
        };
        thread.detach();
    }
}

pub fn decodeQuery(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const out = try a.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const ch = raw[i];
        if (ch == '+') {
            out[n] = ' ';
        } else if (ch == '%' and i + 2 < raw.len) {
            out[n] = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.BadEscape;
            i += 2;
        } else {
            out[n] = ch;
        }
        n += 1;
    }
    return out[0..n];
}

test "decodeQuery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a b/é", try decodeQuery(arena.allocator(), "a+b%2F%C3%A9"));
    try std.testing.expectError(error.BadEscape, decodeQuery(arena.allocator(), "%zz"));
}
