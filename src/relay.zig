//! The phone's side of PocketHarbor's relay. One WebSocket, opened from the
//! phone to the relay that PocketHarbor deployed to the user's Cloudflare
//! account (src/relay/worker.js), carries every visitor's request: nothing
//! listens on the internet and no port is opened. Each request is replayed
//! on the local proxy in a thread of its own, and its response streamed back.

const std = @import("std");
const sys = @import("sys.zig");
const net = @import("net.zig");
const linux = sys.linux;
const Allocator = std.mem.Allocator;

/// What PocketHarbor uploads to Cloudflare.
pub const worker_js = @embedFile("relay/worker.js");

pub const Kind = enum(u8) { head = 1, body = 2, end = 3, res_head = 4, res_body = 5, res_end = 6, abort = 7, _ };

/// The largest piece of body in one frame; Cloudflare caps a WebSocket
/// message at 1 MiB.
pub const chunk = 256 * 1024;

pub fn encode(out: []u8, kind: Kind, id: u32, data: []const u8) []u8 {
    out[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, out[1..5], id, .big);
    @memcpy(out[5..][0..data.len], data);
    return out[0 .. 5 + data.len];
}

pub const Frame = struct { kind: Kind, id: u32, data: []const u8 };

pub fn decode(bytes: []const u8) ?Frame {
    if (bytes.len < 5) return null;
    return .{ .kind = @enumFromInt(bytes[0]), .id = std.mem.readInt(u32, bytes[1..5], .big), .data = bytes[5..] };
}

/// A visitor's request, as the relay describes it.
pub const Head = struct {
    method: []const u8,
    path: []const u8,
    host: ?[]const u8 = null,
    headers: []const [2][]const u8 = &.{},
    length: u64 = 0,
    ip: []const u8 = "",
};

/// Headers that belong to one hop, or that the replay sets itself.
fn hopByHop(name: []const u8) bool {
    const list = [_][]const u8{ "connection", "keep-alive", "upgrade", "transfer-encoding", "te", "trailer", "proxy-connection", "proxy-authorization", "content-length", "host", "x-harbor-host" };
    for (list) |h| if (std.ascii.eqlIgnoreCase(name, h)) return true;
    return false;
}

/// The request as the local proxy receives it: for `host`, from `ip`.
pub fn requestHead(a: Allocator, head: Head, host: []const u8, body_len: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s} {s} HTTP/1.1\r\nHost: {s}\r\n", .{ head.method, head.path, host });
    for (head.headers) |h| {
        if (hopByHop(h[0]) or std.ascii.eqlIgnoreCase(h[0], "x-forwarded-for") or std.ascii.eqlIgnoreCase(h[0], "x-forwarded-proto")) continue;
        if (std.mem.indexOfAny(u8, h[0], "\r\n") != null or std.mem.indexOfAny(u8, h[1], "\r\n") != null) continue;
        try out.print(a, "{s}: {s}\r\n", .{ h[0], h[1] });
    }
    if (head.ip.len > 0) try out.print(a, "X-Forwarded-For: {s}\r\n", .{head.ip});
    try out.appendSlice(a, "X-Forwarded-Proto: https\r\n");
    if (body_len > 0 or !(std.mem.eql(u8, head.method, "GET") or std.mem.eql(u8, head.method, "HEAD"))) {
        try out.print(a, "Content-Length: {d}\r\n", .{body_len});
    }
    try out.appendSlice(a, "Connection: close\r\n\r\n");
    return out.items;
}

pub const ResponseHead = struct {
    status: u16,
    headers: []const [2][]const u8,
    chunked: bool,
    /// The body's length when the service said it; null to read until the end.
    length: ?u64,
};

/// Parses the status line and headers of a response, up to the blank line.
pub fn parseResponseHead(a: Allocator, text: []const u8) !ResponseHead {
    var lines = std.mem.splitSequence(u8, text, "\r\n");
    const status_line = lines.next() orelse return error.BadResponse;
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.BadResponse;
    const sp = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.BadResponse;
    const code_text = std.mem.trim(u8, status_line[sp + 1 ..], " ");
    const status = std.fmt.parseInt(u16, code_text[0..@min(3, code_text.len)], 10) catch return error.BadResponse;
    var headers: std.ArrayList([2][]const u8) = .empty;
    var chunked = false;
    var length: ?u64 = null;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            chunked = std.ascii.findIgnoreCase(value, "chunked") != null;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "content-length")) length = std.fmt.parseInt(u64, value, 10) catch null;
        if (hopByHop(name) and !std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        try headers.append(a, .{ name, value });
    }
    if (chunked) {
        // The body goes back decoded: a length would be wrong.
        var kept: std.ArrayList([2][]const u8) = .empty;
        for (headers.items) |h| if (!std.ascii.eqlIgnoreCase(h[0], "content-length")) try kept.append(a, h);
        headers = kept;
        length = null;
    }
    return .{ .status = status, .headers = headers.items, .chunked = chunked, .length = length };
}

/// Undoes chunked transfer encoding as bytes arrive.
pub const Dechunker = struct {
    state: enum { size, size_ext, size_lf, data, data_cr, data_lf, trailer, trailer_lf, done } = .size,
    left: u64 = 0,
    line_empty: bool = true,

    /// Feeds `in`; calls `out(ctx, piece)` for each piece of the body.
    pub fn feed(self: *Dechunker, in: []const u8, ctx: anytype, comptime out: fn (@TypeOf(ctx), []const u8) anyerror!void) !void {
        var i: usize = 0;
        while (i < in.len) {
            const ch = in[i];
            switch (self.state) {
                .size => {
                    if (std.fmt.charToDigit(ch, 16)) |d| {
                        self.left = self.left * 16 + d;
                    } else |_| {
                        if (ch == ';') self.state = .size_ext else if (ch == '\r') self.state = .size_lf else return error.BadChunk;
                    }
                    i += 1;
                },
                .size_ext => {
                    if (ch == '\r') self.state = .size_lf;
                    i += 1;
                },
                .size_lf => {
                    if (ch != '\n') return error.BadChunk;
                    self.state = if (self.left == 0) .trailer else .data;
                    self.line_empty = true;
                    i += 1;
                },
                .data => {
                    const n: usize = @intCast(@min(self.left, in.len - i));
                    try out(ctx, in[i .. i + n]);
                    self.left -= n;
                    i += n;
                    if (self.left == 0) self.state = .data_cr;
                },
                .data_cr => {
                    if (ch != '\r') return error.BadChunk;
                    self.state = .data_lf;
                    i += 1;
                },
                .data_lf => {
                    if (ch != '\n') return error.BadChunk;
                    self.state = .size;
                    i += 1;
                },
                .trailer => {
                    if (ch == '\r') {
                        self.state = .trailer_lf;
                    } else {
                        self.line_empty = false;
                    }
                    i += 1;
                },
                .trailer_lf => {
                    if (ch != '\n') return error.BadChunk;
                    if (self.line_empty) {
                        self.state = .done;
                        return;
                    }
                    self.state = .trailer;
                    self.line_empty = true;
                    i += 1;
                },
                .done => return,
            }
        }
    }

    pub fn finished(self: Dechunker) bool {
        return self.state == .done;
    }
};

// The WebSocket ----------------------------------------------------------------

const Opcode = enum(u4) { continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10, _ };

/// One connection to the relay, shared by the reader, the keepalive and the
/// threads replaying requests. The last one to let go frees it.
const Session = struct {
    gpa: Allocator,
    io: std.Io,
    client: std.http.Client,
    conn: *std.http.Client.Connection,
    write_lock: std.Io.Mutex = .init,
    alive: std.atomic.Value(bool) = .init(true),
    refs: std.atomic.Value(u32) = .init(1),
    proxy_port: u16,

    fn retain(s: *Session) void {
        _ = s.refs.fetchAdd(1, .monotonic);
    }

    fn release(s: *Session) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        // The client refuses to go while a connection is still in use.
        s.conn.closing = true;
        s.client.connection_pool.release(s.conn, s.io);
        s.client.deinit();
        s.gpa.destroy(s);
    }

    /// Sends one client frame: clients mask what they send.
    fn send(s: *Session, opcode: Opcode, payload: []const u8) !void {
        s.write_lock.lockUncancelable(s.io);
        defer s.write_lock.unlock(s.io);
        if (!s.alive.load(.acquire)) return error.Closed;
        const w = s.conn.writer();
        var head: [14]u8 = undefined;
        head[0] = 0x80 | @as(u8, @intFromEnum(opcode));
        var n: usize = 2;
        if (payload.len < 126) {
            head[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 0xffff) {
            head[1] = 0x80 | 126;
            std.mem.writeInt(u16, head[2..4], @intCast(payload.len), .big);
            n = 4;
        } else {
            head[1] = 0x80 | 127;
            std.mem.writeInt(u64, head[2..10], payload.len, .big);
            n = 10;
        }
        var mask: [4]u8 = undefined;
        s.io.random(&mask);
        @memcpy(head[n..][0..4], &mask);
        n += 4;
        errdefer s.alive.store(false, .release);
        try w.writeAll(head[0..n]);
        var buf: [4096]u8 = undefined;
        var at: usize = 0;
        while (at < payload.len) {
            const len = @min(buf.len, payload.len - at);
            for (0..len) |k| buf[k] = payload[at + k] ^ mask[(at + k) % 4];
            try w.writeAll(buf[0..len]);
            at += len;
        }
        try s.conn.flush();
    }

    fn sendFrame(s: *Session, scratch: []u8, kind: Kind, id: u32, data: []const u8) !void {
        try s.send(.binary, encode(scratch, kind, id, data));
    }

    /// Reads one whole message; answers pings, and fails on close.
    fn readMessage(s: *Session, a: Allocator, out: *std.ArrayList(u8)) !Opcode {
        const r = s.conn.reader();
        out.clearRetainingCapacity();
        var first: ?Opcode = null;
        while (true) {
            const b0 = try r.takeByte();
            const b1 = try r.takeByte();
            const fin = b0 & 0x80 != 0;
            const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0)));
            var len: u64 = b1 & 0x7f;
            if (len == 126) {
                var ext: [2]u8 = undefined;
                try r.readSliceAll(&ext);
                len = std.mem.readInt(u16, &ext, .big);
            } else if (len == 127) {
                var ext: [8]u8 = undefined;
                try r.readSliceAll(&ext);
                len = std.mem.readInt(u64, &ext, .big);
            }
            if (len > 16 << 20) return error.TooLarge;
            var mask: ?[4]u8 = null;
            if (b1 & 0x80 != 0) {
                var m: [4]u8 = undefined;
                try r.readSliceAll(&m);
                mask = m;
            }
            const start = out.items.len;
            try out.resize(a, start + @as(usize, @intCast(len)));
            try r.readSliceAll(out.items[start..]);
            if (mask) |m| for (out.items[start..], 0..) |*c, k| {
                c.* ^= m[k % 4];
            };
            switch (opcode) {
                .ping => {
                    const payload = try a.dupe(u8, out.items[start..]);
                    out.shrinkRetainingCapacity(start);
                    s.send(.pong, payload) catch {};
                    continue;
                },
                .pong => {
                    out.shrinkRetainingCapacity(start);
                    continue;
                },
                .close => return error.Closed,
                else => {},
            }
            if (first == null) first = opcode;
            if (fin) return first.?;
        }
    }
};

const UrlParts = struct { tls: bool, host: []const u8, port: u16, path: []const u8 };

/// "wss://host[:port]/path" or "ws://...".
fn splitUrl(url: []const u8) !UrlParts {
    const tls = std.mem.startsWith(u8, url, "wss://");
    if (!tls and !std.mem.startsWith(u8, url, "ws://")) return error.BadUrl;
    const rest = url[if (tls) 6 else 5..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash == rest.len) "/" else rest[slash..];
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        return .{ .tls = tls, .host = authority[0..colon], .port = try std.fmt.parseInt(u16, authority[colon + 1 ..], 10), .path = path };
    }
    return .{ .tls = tls, .host = authority, .port = if (tls) 443 else 80, .path = path };
}

/// Opens the WebSocket to `url` (wss://, or ws:// for tests) with the secret.
fn open(gpa: Allocator, io: std.Io, url: []const u8, secret: []const u8, proxy_port: u16) !*Session {
    const parts = try splitUrl(url);
    const tls = parts.tls;
    const host = try std.Io.net.HostName.init(parts.host);
    const port = parts.port;
    const path = parts.path;

    const s = try gpa.create(Session);
    errdefer gpa.destroy(s);
    s.* = .{ .gpa = gpa, .io = io, .client = .{ .allocator = gpa, .io = io }, .conn = undefined, .proxy_port = proxy_port };
    errdefer s.client.deinit();
    if (tls) {
        var bundle: std.crypto.Certificate.Bundle = .empty;
        const now = std.Io.Clock.real.now(io);
        bundle.rescan(gpa, io, now) catch return error.CertificatesUnreadable;
        s.client.ca_bundle = bundle;
        s.client.now = now;
    }
    s.conn = try s.client.connectTcpOptions(.{ .host = host, .port = port, .protocol = if (tls) .tls else .plain });
    errdefer {
        s.conn.closing = true;
        s.client.connection_pool.release(s.conn, io);
    }

    var key_raw: [16]u8 = undefined;
    io.random(&key_raw);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &key_raw);
    const w = s.conn.writer();
    try w.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {s}\r\nUser-Agent: pocketharbor\r\n\r\n", .{ path, parts.host, &key, secret });
    try s.conn.flush();
    const r = s.conn.reader();
    const status = try r.takeDelimiterInclusive('\n');
    const switched = std.mem.indexOf(u8, status, " 101") != null;
    const forbidden = std.mem.indexOf(u8, status, " 403") != null;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r\n"), "")) break;
    }
    if (forbidden) return error.Forbidden;
    if (!switched) return error.NoUpgrade;
    return s;
}

// Replaying a request ------------------------------------------------------------

const Job = struct {
    session: *Session,
    id: u32,
    head: Head,
    body: []u8,
    arena: std.heap.ArenaAllocator,
};

fn connectProxy(port: u16) !i32 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    const fd: i32 = @intCast(try sys.ck(rc));
    errdefer sys.close(fd);
    // A service that never answers frees the thread after two minutes.
    const tv = linux.timeval{ .sec = 120, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
    var sa = net.loopback(port);
    _ = try sys.ck(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
    return fd;
}

const BodyOut = struct {
    session: *Session,
    id: u32,
    scratch: []u8,
    sent: u64 = 0,

    fn put(self: *BodyOut, piece: []const u8) anyerror!void {
        var at: usize = 0;
        while (at < piece.len) {
            const n = @min(chunk, piece.len - at);
            try self.session.sendFrame(self.scratch, .res_body, self.id, piece[at .. at + n]);
            self.sent += n;
            at += n;
        }
    }
};

fn replay(job: *Job) void {
    defer {
        job.session.release();
        job.arena.deinit();
        std.heap.smp_allocator.destroy(job);
    }
    const a = job.arena.allocator();
    const s = job.session;
    const scratch = a.alloc(u8, 5 + chunk) catch return;
    run(job, a, scratch) catch |e| {
        const why = std.fmt.allocPrint(a, "The phone could not reach the service: {s}", .{@errorName(e)}) catch "The phone could not reach the service";
        s.sendFrame(scratch, .abort, job.id, why) catch {};
    };
}

fn run(job: *Job, a: Allocator, scratch: []u8) !void {
    const s = job.session;
    const host = job.head.host orelse return error.NoHost;
    const fd = try connectProxy(s.proxy_port);
    defer sys.close(fd);
    try sys.writeAll(fd, try requestHead(a, job.head, host, job.body.len));
    if (job.body.len > 0) try sys.writeAll(fd, job.body);

    // The head, then whatever of the body came with it.
    var buf = try a.alloc(u8, 64 * 1024);
    var have: usize = 0;
    const end = while (true) {
        if (have == buf.len) return error.HeadersTooLarge;
        const n = try sys.read(fd, buf[have..]);
        if (n == 0) return error.NoResponse;
        have += n;
        if (std.mem.indexOf(u8, buf[0..have], "\r\n\r\n")) |i| break i + 4;
    };
    const head = try parseResponseHead(a, buf[0..end]);
    try s.sendFrame(scratch, .res_head, job.id, try std.json.Stringify.valueAlloc(a, .{ .status = head.status, .headers = head.headers }, .{}));

    var out: BodyOut = .{ .session = s, .id = job.id, .scratch = scratch };
    var dechunk: Dechunker = .{};
    var pending = buf[end..have];
    const no_body = std.mem.eql(u8, job.head.method, "HEAD") or head.status == 204 or head.status == 304 or (head.status >= 100 and head.status < 200);
    while (!no_body) {
        if (pending.len > 0) {
            if (head.chunked) {
                try dechunk.feed(pending, &out, BodyOut.put);
                if (dechunk.finished()) break;
            } else {
                const take: usize = if (head.length) |l| @intCast(@min(l - out.sent, pending.len)) else pending.len;
                try out.put(pending[0..take]);
            }
        }
        if (head.length) |l| if (out.sent >= l) break;
        const n = sys.read(fd, buf) catch |e| {
            if (head.length == null and !head.chunked) break;
            return e;
        };
        if (n == 0) {
            if (head.chunked and !dechunk.finished()) return error.TruncatedBody;
            if (head.length) |l| if (out.sent < l) return error.TruncatedBody;
            break;
        }
        pending = buf[0..n];
    }
    try s.sendFrame(scratch, .res_end, job.id, "");
}

// The loop -----------------------------------------------------------------------

const Building = struct { head: Head, body: std.ArrayList(u8), arena: std.heap.ArenaAllocator };

fn keepalive(s: *Session) void {
    defer s.release();
    while (s.alive.load(.acquire)) {
        var waited: u32 = 0;
        while (waited < 25 and s.alive.load(.acquire)) : (waited += 1) sys.sleepMs(1000);
        s.send(.text, "ping") catch return;
    }
}

/// Serves requests until the connection drops.
fn serve(s: *Session) !void {
    const gpa = s.gpa;
    var building: std.AutoHashMapUnmanaged(u32, *Building) = .empty;
    defer {
        var it = building.valueIterator();
        while (it.next()) |b| {
            b.*.arena.deinit();
            gpa.destroy(b.*);
        }
        building.deinit(gpa);
    }
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    var scratch_arena = std.heap.ArenaAllocator.init(gpa);
    defer scratch_arena.deinit();
    while (true) {
        _ = scratch_arena.reset(.retain_capacity);
        const opcode = try s.readMessage(gpa, &msg);
        if (opcode != .binary) continue;
        const f = decode(msg.items) orelse continue;
        switch (f.kind) {
            .head => {
                const b = try gpa.create(Building);
                b.* = .{ .head = undefined, .body = .empty, .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator) };
                b.head = std.json.parseFromSliceLeaky(Head, b.arena.allocator(), f.data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
                    b.arena.deinit();
                    gpa.destroy(b);
                    continue;
                };
                try building.put(gpa, f.id, b);
            },
            .body => if (building.get(f.id)) |b| try b.body.appendSlice(b.arena.allocator(), f.data),
            .end => if (building.fetchRemove(f.id)) |kv| {
                const b = kv.value;
                defer gpa.destroy(b);
                const job = try std.heap.smp_allocator.create(Job);
                job.* = .{ .session = s, .id = f.id, .head = b.head, .body = b.body.items, .arena = b.arena };
                s.retain();
                const thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, replay, .{job}) catch {
                    s.release();
                    job.arena.deinit();
                    std.heap.smp_allocator.destroy(job);
                    continue;
                };
                thread.detach();
            },
            else => {},
        }
    }
}

pub const Config = struct { url: []const u8, secret: []const u8, proxy_port: u16 };

/// Connects, serves, and connects again, waiting longer after each failure.
/// `config` is asked again before each attempt, so that a change of relay
/// or a disconnection is followed; null means there is no relay to use.
pub fn loop(gpa: Allocator, io: std.Io, ctx: anytype, comptime config: fn (@TypeOf(ctx)) ?Config) noreturn {
    var backoff_ms: u64 = 1000;
    while (true) {
        const c = config(ctx) orelse {
            sys.sleepMs(15_000);
            continue;
        };
        if (open(gpa, io, c.url, c.secret, c.proxy_port)) |s| {
            sys.print("relay: connected to {s}\n", .{c.url});
            backoff_ms = 1000;
            s.retain();
            if (std.Thread.spawn(.{ .stack_size = 256 * 1024 }, keepalive, .{s})) |th| th.detach() else |_| s.release();
            serve(s) catch |e| sys.eprint("relay: connection lost ({s})\n", .{@errorName(e)});
            s.alive.store(false, .release);
            s.release();
        } else |e| {
            sys.eprint("relay: cannot connect to {s} ({s})\n", .{ c.url, @errorName(e) });
            if (e == error.Forbidden) backoff_ms = 60_000;
        }
        sys.sleepMs(backoff_ms);
        backoff_ms = @min(backoff_ms * 2, 60_000);
    }
}

const t = std.testing;

test "frames carry a type, an id and data" {
    var buf: [32]u8 = undefined;
    const f = encode(&buf, .res_body, 0x01020304, "abc");
    try t.expectEqualSlices(u8, &.{ 5, 1, 2, 3, 4, 'a', 'b', 'c' }, f);
    const back = decode(f).?;
    try t.expectEqual(Kind.res_body, back.kind);
    try t.expectEqual(@as(u32, 0x01020304), back.id);
    try t.expectEqualStrings("abc", back.data);
    try t.expect(decode("abc") == null);
}

test "the replayed request names the service and the visitor" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const head: Head = .{
        .method = "POST",
        .path = "/api?x=1",
        .headers = &.{ .{ "Content-Type", "application/json" }, .{ "Host", "evil" }, .{ "Connection", "keep-alive" }, .{ "X-Forwarded-For", "6.6.6.6" }, .{ "Bad\r\nInjected", "x" } },
        .ip = "203.0.113.7",
    };
    const text = try requestHead(arena.allocator(), head, "web-1a2b.example.workers.dev", 2);
    try t.expectEqualStrings(
        "POST /api?x=1 HTTP/1.1\r\nHost: web-1a2b.example.workers.dev\r\nContent-Type: application/json\r\nX-Forwarded-For: 203.0.113.7\r\nX-Forwarded-Proto: https\r\nContent-Length: 2\r\nConnection: close\r\n\r\n",
        text,
    );
}

test "a chunked response goes back decoded, without its length" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = try parseResponseHead(a, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nConnection: close\r\n\r\n");
    try t.expectEqual(@as(u16, 200), head.status);
    try t.expect(head.chunked);
    try t.expectEqual(@as(usize, 3), head.headers.len);
    try t.expectEqualStrings("b=2", head.headers[2][1]);

    const Sink = struct {
        list: *std.ArrayList(u8),
        al: Allocator,
        fn put(self: @This(), piece: []const u8) anyerror!void {
            try self.list.appendSlice(self.al, piece);
        }
    };
    var body: std.ArrayList(u8) = .empty;
    var d: Dechunker = .{};
    const sink: Sink = .{ .list = &body, .al = a };
    // Split anywhere, as reads split it.
    const wire = "5\r\nhello\r\n7;ext=1\r\n, world\r\n0\r\nX-Trailer: y\r\n\r\n";
    for (wire) |ch| try d.feed(&.{ch}, sink, Sink.put);
    try t.expect(d.finished());
    try t.expectEqualStrings("hello, world", body.items);
}

test "relay addresses" {
    const p = try splitUrl("wss://pocketharbor-02f48b.example.workers.dev/__harbor/connect");
    try t.expect(p.tls);
    try t.expectEqualStrings("pocketharbor-02f48b.example.workers.dev", p.host);
    try t.expectEqual(@as(u16, 443), p.port);
    try t.expectEqualStrings("/__harbor/connect", p.path);
    const q = try splitUrl("ws://127.0.0.1:8787/__harbor/connect");
    try t.expect(!q.tls);
    try t.expectEqual(@as(u16, 8787), q.port);
    try t.expectError(error.BadUrl, splitUrl("https://x"));
}

test "a plain response keeps its length" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const head = try parseResponseHead(arena.allocator(), "HTTP/1.1 404 Not Found\r\nContent-Length: 12\r\n\r\n");
    try t.expectEqual(@as(u16, 404), head.status);
    try t.expectEqual(@as(?u64, 12), head.length);
    try t.expectEqualStrings("Content-Length", head.headers[0][0]);
}
