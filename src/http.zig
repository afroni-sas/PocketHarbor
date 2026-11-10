//! Just enough HTTP/1.x to route a request and pass it on.
//!
//! The proxy serves one request per connection, so it never has to find where
//! a body ends: it reads the head, forwards it with `Connection: close`, and
//! copies bytes until the upstream closes. WebSockets fall out of the same
//! copying. That also takes away what request smuggling relies on, since no
//! upstream connection ever carries a second request.

const std = @import("std");
const ascii = std.ascii;

pub const max_head = 16 * 1024;
/// How much bigger `rewrite` can make a head.
pub const rewrite_margin = 1024;

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    host: []const u8,
    upgrade: bool = false,
    forwarded_for: []const u8 = "",
    forwarded_proto: []const u8 = "",
    cf_ip: []const u8 = "",
};

/// Offset just past the blank line that ends a head, once it has arrived.
pub fn headEnd(data: []const u8) ?usize {
    const i = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
    return i + 4;
}

const Header = struct { name: []const u8, value: []const u8, raw: []const u8 };

const Headers = struct {
    rest: []const u8,

    fn next(self: *Headers) error{BadRequest}!?Header {
        const eol = std.mem.indexOf(u8, self.rest, "\r\n") orelse return error.BadRequest;
        if (eol == 0) return null;
        const raw = self.rest[0..eol];
        self.rest = self.rest[eol + 2 ..];
        // Obsolete line folding is a classic way to disagree with a parser.
        if (raw[0] == ' ' or raw[0] == '\t') return error.BadRequest;
        for (raw) |ch| {
            if (ch == 0 or ch == '\r' or ch == '\n') return error.BadRequest;
        }
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return error.BadRequest;
        const name = raw[0..colon];
        if (name.len == 0) return error.BadRequest;
        for (name) |ch| {
            if (ch <= ' ' or ch == 0x7f) return error.BadRequest;
        }
        return .{ .name = name, .value = std.mem.trim(u8, raw[colon + 1 ..], " \t"), .raw = raw };
    }
};

fn isToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", ch) == null) return false;
    }
    return true;
}

fn hasToken(list: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, ", \t");
    while (it.next()) |item| {
        if (ascii.eqlIgnoreCase(item, token)) return true;
    }
    return false;
}

const eq = ascii.eqlIgnoreCase;

/// Parses a complete head, which must end with the blank line.
pub fn parseRequest(head: []const u8) error{BadRequest}!Request {
    const eol = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, head[0..eol], ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version = parts.next() orelse return error.BadRequest;
    if (parts.next() != null or !isToken(method)) return error.BadRequest;
    if (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0")) return error.BadRequest;
    if (eq(method, "CONNECT") or target.len == 0) return error.BadRequest;
    if (target[0] != '/' and !std.mem.eql(u8, target, "*")) return error.BadRequest;

    var req: Request = .{ .method = method, .target = target, .host = "" };
    var has_host = false;
    var length: ?[]const u8 = null;
    var chunked = false;
    var connection_upgrade = false;
    var upgrade_header = false;

    var it: Headers = .{ .rest = head[eol + 2 ..] };
    while (try it.next()) |h| {
        if (eq(h.name, "host")) {
            if (has_host and !std.mem.eql(u8, req.host, h.value)) return error.BadRequest;
            has_host = true;
            req.host = h.value;
        } else if (eq(h.name, "content-length")) {
            if (length != null and !std.mem.eql(u8, length.?, h.value)) return error.BadRequest;
            length = h.value;
            _ = std.fmt.parseInt(u64, h.value, 10) catch return error.BadRequest;
        } else if (eq(h.name, "transfer-encoding")) {
            chunked = true;
        } else if (eq(h.name, "connection")) {
            if (hasToken(h.value, "upgrade")) connection_upgrade = true;
        } else if (eq(h.name, "upgrade")) {
            upgrade_header = true;
        } else if (eq(h.name, "x-forwarded-for")) {
            req.forwarded_for = h.value;
        } else if (eq(h.name, "x-forwarded-proto")) {
            req.forwarded_proto = h.value;
        } else if (eq(h.name, "cf-connecting-ip")) {
            req.cf_ip = h.value;
        }
    }
    if (!has_host or req.host.len == 0) return error.BadRequest;
    if (length != null and chunked) return error.BadRequest;
    req.upgrade = connection_upgrade and upgrade_header;
    return req;
}

/// Lowercases a Host value and drops its port.
pub fn normalizeHost(host: []const u8, out: []u8) error{BadRequest}![]const u8 {
    var name = host;
    if (name.len > 0 and name[0] == '[') {
        const end = std.mem.indexOfScalar(u8, name, ']') orelse return error.BadRequest;
        name = name[0 .. end + 1];
    } else if (std.mem.indexOfScalar(u8, name, ':')) |i| {
        name = name[0..i];
    }
    if (name.len == 0 or name.len > out.len) return error.BadRequest;
    return ascii.lowerString(out, name);
}

/// Copies a head into `out` ready for the upstream. `trusted` means the peer
/// is local, like the tunnel, so what it says about the real client stands.
pub fn rewrite(out: []u8, head: []const u8, req: Request, peer: []const u8, trusted: bool) error{ BadRequest, NoSpaceLeft }!usize {
    var n: usize = 0;
    const put = struct {
        fn f(o: []u8, pos: *usize, s: []const u8) error{NoSpaceLeft}!void {
            if (pos.* + s.len > o.len) return error.NoSpaceLeft;
            @memcpy(o[pos.*..][0..s.len], s);
            pos.* += s.len;
        }
    }.f;

    const eol = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadRequest;
    try put(out, &n, head[0 .. eol + 2]);

    var it: Headers = .{ .rest = head[eol + 2 ..] };
    var host_value: []const u8 = "";
    while (try it.next()) |h| {
        if (eq(h.name, "host")) host_value = h.value;
        const hop_by_hop = eq(h.name, "connection") or eq(h.name, "keep-alive") or
            eq(h.name, "proxy-connection") or eq(h.name, "te") or eq(h.name, "trailer") or
            (eq(h.name, "upgrade") and !req.upgrade);
        const spoofable = !trusted and (eq(h.name, "x-forwarded-for") or
            eq(h.name, "x-forwarded-proto") or eq(h.name, "x-forwarded-host") or
            eq(h.name, "cf-connecting-ip"));
        if (hop_by_hop or spoofable) continue;
        try put(out, &n, h.raw);
        try put(out, &n, "\r\n");
    }

    try put(out, &n, if (req.upgrade) "Connection: Upgrade\r\n" else "Connection: close\r\n");
    if (!trusted or req.forwarded_for.len == 0) {
        try put(out, &n, "X-Forwarded-For: ");
        try put(out, &n, peer);
        try put(out, &n, "\r\n");
    }
    if (!trusted or req.forwarded_proto.len == 0) try put(out, &n, "X-Forwarded-Proto: http\r\n");
    try put(out, &n, "X-Forwarded-Host: ");
    try put(out, &n, host_value);
    try put(out, &n, "\r\n\r\n");
    return n;
}

/// The status of a response whose beginning is in `data`, skipping interim
/// `100 Continue` responses. Returns null until the status line has arrived.
pub fn responseStatus(data: []const u8) ?u16 {
    var rest = data;
    while (true) {
        if (rest.len < 12 or !std.mem.startsWith(u8, rest, "HTTP/1.")) return null;
        const code = std.fmt.parseInt(u16, rest[9..12], 10) catch return null;
        if (code != 100) return code;
        const end = headEnd(rest) orelse return null;
        rest = rest[end..];
    }
}

pub fn reason(status: u16) []const u8 {
    return switch (status) {
        400 => "Bad Request",
        404 => "Not Found",
        431 => "Request Header Fields Too Large",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Error",
    };
}

/// Writes a complete response with a small HTML page.
pub fn page(out: []u8, status: u16, detail: []const u8) []const u8 {
    var body_buf: [768]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        \\<!doctype html><meta charset="utf-8"><title>{d} {s}</title>
        \\<body style="font:16px system-ui;background:#1e2a44;color:#fff;display:grid;place-items:center;height:100vh;margin:0">
        \\<div style="text-align:center"><h1 style="color:#4ade80;margin:0">{d}</h1><p>{s}</p></div>
    , .{ status, reason(status), status, detail }) catch "";
    return std.fmt.bufPrint(out, "HTTP/1.1 {d} {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, reason(status), body.len, body }) catch "";
}

const t = std.testing;

test "parses a plain request" {
    const r = try parseRequest("GET /a?b=1 HTTP/1.1\r\nHost: Example.com:8080\r\nUser-Agent: x\r\n\r\n");
    try t.expectEqualStrings("GET", r.method);
    try t.expectEqualStrings("/a?b=1", r.target);
    try t.expectEqualStrings("Example.com:8080", r.host);
    try t.expect(!r.upgrade);
}

test "recognises a websocket upgrade" {
    const r = try parseRequest("GET /ws HTTP/1.1\r\nHost: a\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n\r\n");
    try t.expect(r.upgrade);
}

test "an Upgrade header alone is not an upgrade" {
    const r = try parseRequest("GET / HTTP/1.1\r\nHost: a\r\nUpgrade: websocket\r\n\r\n");
    try t.expect(!r.upgrade);
}

test "refuses what could smuggle a request" {
    const bad = [_][]const u8{
        "GET / HTTP/1.1\r\n\r\n",
        "GET / HTTP/2.0\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: abc\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\n folded: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nBad Name: x\r\n\r\n",
        "CONNECT a:443 HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET http://a/ HTTP/1.1\r\nHost: a\r\n\r\n",
    };
    for (bad) |b| try t.expectError(error.BadRequest, parseRequest(b));
}

test "normalises hosts" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("example.com", try normalizeHost("EXAMPLE.com:443", &buf));
    try t.expectEqualStrings("[::1]", try normalizeHost("[::1]:80", &buf));
}

test "drops what a remote client may not assert" {
    const head = "GET / HTTP/1.1\r\nHost: a\r\nConnection: keep-alive\r\nX-Forwarded-For: 6.6.6.6\r\nCF-Connecting-IP: 6.6.6.6\r\nAccept: */*\r\n\r\n";
    var out: [512]u8 = undefined;
    const n = try rewrite(&out, head, try parseRequest(head), "1.2.3.4", false);
    const got = out[0..n];
    try t.expect(std.mem.indexOf(u8, got, "6.6.6.6") == null);
    try t.expect(std.mem.indexOf(u8, got, "keep-alive") == null);
    try t.expect(std.mem.indexOf(u8, got, "X-Forwarded-For: 1.2.3.4\r\n") != null);
    try t.expect(std.mem.indexOf(u8, got, "Connection: close\r\n") != null);
    try t.expect(std.mem.indexOf(u8, got, "Accept: */*\r\n") != null);
    try t.expect(std.mem.endsWith(u8, got, "\r\n\r\n"));
}

test "believes the local tunnel about the real client" {
    const head = "GET / HTTP/1.1\r\nHost: a\r\nX-Forwarded-For: 9.9.9.9\r\nX-Forwarded-Proto: https\r\n\r\n";
    var out: [512]u8 = undefined;
    const n = try rewrite(&out, head, try parseRequest(head), "127.0.0.1", true);
    const got = out[0..n];
    try t.expect(std.mem.indexOf(u8, got, "X-Forwarded-For: 9.9.9.9\r\n") != null);
    try t.expect(std.mem.indexOf(u8, got, "X-Forwarded-Proto: https\r\n") != null);
    try t.expect(std.mem.indexOf(u8, got, "127.0.0.1") == null);
}

test "keeps the upgrade headers of a websocket" {
    const head = "GET /ws HTTP/1.1\r\nHost: a\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: k\r\n\r\n";
    var out: [512]u8 = undefined;
    const n = try rewrite(&out, head, try parseRequest(head), "1.2.3.4", false);
    const got = out[0..n];
    try t.expect(std.mem.indexOf(u8, got, "Upgrade: websocket\r\n") != null);
    try t.expect(std.mem.indexOf(u8, got, "Connection: Upgrade\r\n") != null);
    try t.expect(std.mem.indexOf(u8, got, "Sec-WebSocket-Key: k\r\n") != null);
}

test "reads the response status" {
    try t.expectEqual(@as(?u16, 200), responseStatus("HTTP/1.1 200 OK\r\n\r\n"));
    try t.expectEqual(@as(?u16, 404), responseStatus("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 404 Not Found\r\n\r\n"));
    try t.expectEqual(@as(?u16, null), responseStatus("HTTP/1.1 100 Continue\r\n\r\n"));
    try t.expectEqual(@as(?u16, null), responseStatus("HTT"));
}
