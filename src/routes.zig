//! The table the proxy consults: which service answers for which hostname.

const std = @import("std");

pub const Route = struct {
    /// `app.example.com`, `*.example.com`, or `*` for anything else.
    host: []const u8,
    service: []const u8,
    /// Where the service listens on the phone's loopback.
    port: u16 = 0,
    asleep: bool = false,
    sleep_after_s: u32 = 0,
};

/// The route of the panel itself, which never sleeps.
pub const panel_service = "pharbor.panel";

pub const Document = struct {
    routes: []const Route = &.{},
    /// Requests by IP address or `localhost` reach the panel.
    panel_port: u16 = 0,
};

pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    routes: []const Route = &.{},
    panel_port: u16 = 0,

    pub fn empty(gpa: std.mem.Allocator) Table {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn parse(gpa: std.mem.Allocator, json: []const u8) !Table {
        var table = empty(gpa);
        errdefer table.arena.deinit();
        const parsed = try std.json.parseFromSliceLeaky(Document, table.arena.allocator(), json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        table.routes = parsed.routes;
        table.panel_port = parsed.panel_port;
        return table;
    }

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
    }

    /// An exact name wins, then the longest wildcard, then the catch-all.
    pub fn lookup(self: *const Table, host: []const u8) ?*const Route {
        var best: ?*const Route = null;
        var best_len: usize = 0;
        var fallback: ?*const Route = null;
        for (self.routes) |*r| {
            if (std.ascii.eqlIgnoreCase(r.host, host)) return r;
            if (std.mem.eql(u8, r.host, "*")) {
                fallback = r;
            } else if (std.mem.startsWith(u8, r.host, "*.")) {
                const suffix = r.host[1..];
                if (host.len > suffix.len and std.ascii.endsWithIgnoreCase(host, suffix) and suffix.len > best_len) {
                    best = r;
                    best_len = suffix.len;
                }
            }
        }
        return best orelse fallback;
    }
};

const t = std.testing;

const doc =
    \\{"routes":[
    \\ {"host":"app.example.com","service":"app","port":20001},
    \\ {"host":"*.example.com","service":"wild","port":20002},
    \\ {"host":"*.deep.example.com","service":"deep","port":20003,"asleep":true},
    \\ {"host":"*","service":"other","port":20004}
    \\]}
;

test "exact names beat wildcards" {
    var table = try Table.parse(t.allocator, doc);
    defer table.deinit();
    try t.expectEqualStrings("app", table.lookup("app.example.com").?.service);
    try t.expectEqualStrings("app", table.lookup("APP.example.com").?.service);
}

test "the longest wildcard wins" {
    var table = try Table.parse(t.allocator, doc);
    defer table.deinit();
    try t.expectEqualStrings("wild", table.lookup("x.example.com").?.service);
    const r = table.lookup("a.deep.example.com").?;
    try t.expectEqualStrings("deep", r.service);
    try t.expect(r.asleep);
}

test "a wildcard does not match its bare domain" {
    var table = try Table.parse(t.allocator, doc);
    defer table.deinit();
    try t.expectEqualStrings("other", table.lookup("example.com").?.service);
}

test "without a catch-all an unknown name finds nothing" {
    var table = try Table.parse(t.allocator, "{\"routes\":[{\"host\":\"a.b\",\"service\":\"s\",\"port\":1}]}");
    defer table.deinit();
    try t.expect(table.lookup("c.d") == null);
}
