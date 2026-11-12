//! Custom domains as Railway sets them up: the DNS record each one needs,
//! and a check that the name really reaches this installation, whatever
//! carries it (a Cloudflare tunnel, a record on the local network).

const std = @import("std");
const sys = @import("sys.zig");
const linux = sys.linux;
const Allocator = std.mem.Allocator;

/// How long one attempt may take: a firewall that drops packets would
/// otherwise hold a connection for two minutes.
const attempt_ms = 4000;

/// The path every hostname sends to the panel; it answers the check id.
pub const check_path = "/__pharbor/check";

pub const Record = struct {
    type: []const u8,
    /// Relative to the zone, as DNS providers ask for it: "app", or "@".
    name: []const u8,
    value: []const u8,
    /// Cloudflare's orange cloud.
    proxied: bool = false,
};

/// Suffixes under which a registrable domain has three labels.
const three_label_zones = [_][]const u8{
    "co.uk",  "org.uk", "ac.uk",  "me.uk",  "com.au", "net.au", "org.au", "co.nz",  "co.jp",
    "co.za",  "com.br", "com.mx", "co.in",  "co.kr",  "com.cn", "com.tr", "com.ar", "co.id",
    "com.sg", "com.ng", "co.ke",  "com.eg", "co.ma",  "com.tn", "co.il",  "com.co", "com.pe",
};

pub const Split = struct { name: []const u8, zone: []const u8 };

/// "api.app.example.com" → "api.app" in the zone "example.com"; a zone's
/// own name is "@".
pub fn split(domain: []const u8) Split {
    var labels: usize = 1;
    for (domain) |ch| {
        if (ch == '.') labels += 1;
    }
    var zone_labels: usize = 2;
    for (three_label_zones) |suffix| {
        if (domain.len > suffix.len and std.mem.endsWith(u8, domain, suffix) and domain[domain.len - suffix.len - 1] == '.') {
            zone_labels = 3;
            break;
        }
    }
    if (labels <= zone_labels) return .{ .name = "@", .zone = domain };
    var dots: usize = 0;
    var i = domain.len;
    while (i > 0) {
        i -= 1;
        if (domain[i] == '.') {
            dots += 1;
            if (dots == zone_labels) break;
        }
    }
    return .{ .name = domain[0..i], .zone = domain[i + 1 ..] };
}

/// How names reach this installation.
pub const Setup = union(enum) {
    /// A Cloudflare tunnel, by its id.
    tunnel: []const u8,
    /// The device's address on its network.
    lan: [4]u8,
    none,
};

/// The record to add at the DNS provider for `domain`.
pub fn records(a: Allocator, domain: []const u8, setup: Setup) ![]const Record {
    const name = split(domain).name;
    return switch (setup) {
        .tunnel => |id| try a.dupe(Record, &.{.{
            .type = "CNAME",
            .name = name,
            .value = try std.fmt.allocPrint(a, "{s}.cfargotunnel.com", .{id}),
            .proxied = true,
        }}),
        .lan => |ip| try a.dupe(Record, &.{.{
            .type = "A",
            .name = name,
            .value = try std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }),
        }}),
        .none => &.{},
    };
}

pub const Status = enum {
    /// The name reaches this installation.
    active,
    /// The name does not resolve yet.
    dns,
    /// It resolves to Cloudflare, which does not send it here: the tunnel
    /// has no public hostname for it.
    cloudflare,
    /// Another server answers for it.
    elsewhere,
    /// It resolves, but nothing accepts the connection.
    no_answer,

    fn rank(self: Status) u8 {
        return switch (self) {
            .active => 4,
            .cloudflare, .elsewhere => 3,
            .no_answer => 2,
            .dns => 1,
        };
    }
};

pub const Result = struct {
    status: Status,
    /// How it was reached: "https", or "http" with a port.
    via: []const u8 = "",
    detail: []const u8 = "",
};

/// A wildcard is checked through one name it covers.
fn probeHost(a: Allocator, domain: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, domain, "*.")) return std.fmt.allocPrint(a, "pharbor-check.{s}", .{domain[2..]});
    return domain;
}

/// Asks public DNS first: a name that does not exist there is waiting for
/// its record, and finding that out through the system's resolver can take
/// it 40 seconds. Then asks the name for the check id over HTTPS, then over
/// HTTP on the proxy's port and on 80, and reports the most telling answer.
pub fn check(a: Allocator, gpa: Allocator, io: std.Io, domain: []const u8, proxy_port: u16, want: []const u8) !Result {
    const host = try probeHost(a, domain);
    const public = runTimed(Lookup, a, Lookup.Job{ .a = a, .gpa = gpa, .io = io, .host = host });
    var tries: [3]struct { url: []const u8, via: []const u8 } = undefined;
    var n: usize = 0;
    // A name that is not in public DNS can still be on a local one: the
    // network's own port is all that is worth trying then.
    const missing = public != null and !public.?.exists;
    if (!missing) {
        tries[n] = .{ .url = try std.fmt.allocPrint(a, "https://{s}{s}", .{ host, check_path }), .via = "https" };
        n += 1;
    }
    if (proxy_port != 80) {
        tries[n] = .{ .url = try std.fmt.allocPrint(a, "http://{s}:{d}{s}", .{ host, proxy_port, check_path }), .via = try std.fmt.allocPrint(a, "http, port {d}", .{proxy_port}) };
        n += 1;
    }
    if (!missing or proxy_port == 80) {
        tries[n] = .{ .url = try std.fmt.allocPrint(a, "http://{s}{s}", .{ host, check_path }), .via = "http" };
        n += 1;
    }

    var best: Result = .{ .status = .dns, .detail = "the name does not resolve" };
    for (tries[0..n]) |attempt| {
        var r = runTimed(Result, a, Probe{ .a = a, .gpa = gpa, .io = io, .url = attempt.url, .want = want }) orelse
            Result{ .status = .no_answer, .detail = "no answer within 4 seconds" };
        if (r.status == .active) {
            r.via = attempt.via;
            return r;
        }
        if (r.status.rank() > best.status.rank()) best = r;
        // A name that does not resolve fails the same way on every port, and
        // one whose HTTPS another server answers points elsewhere.
        if (r.status != .no_answer) break;
    }
    if (missing) return .{ .status = .dns, .detail = "public DNS does not know the name yet" };
    if (best.status == .no_answer) {
        if (public) |p| {
            if (p.address.len > 0) best.detail = try std.fmt.allocPrint(a, "it points to {s}, where nothing answers", .{p.address});
        }
    }
    return best;
}

/// What public DNS says about a name, through Cloudflare's DNS over HTTPS.
const Lookup = struct {
    exists: bool,
    address: []const u8 = "",

    const Job = struct {
        a: Allocator,
        gpa: Allocator,
        io: std.Io,
        host: []const u8,

        fn run(self: Job) ?Lookup {
            for ([_][]const u8{ "A", "AAAA" }) |kind| {
                const found = query(self, kind) orelse return null;
                if (found.exists) return found;
            }
            return .{ .exists = false };
        }

        fn query(self: Job, kind: []const u8) ?Lookup {
            var http: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
            defer http.deinit();
            const url = std.fmt.allocPrint(self.a, "https://1.1.1.1/dns-query?name={s}&type={s}", .{ self.host, kind }) catch return null;
            var req = http.request(.GET, std.Uri.parse(url) catch return null, .{
                .keep_alive = false,
                .headers = .{ .accept_encoding = .omit, .user_agent = .{ .override = "pocketharbor-domain-check" } },
                .extra_headers = &.{.{ .name = "Accept", .value = "application/dns-json" }},
            }) catch return null;
            defer req.deinit();
            req.sendBodiless() catch return null;
            var head_buf: [8192]u8 = undefined;
            var resp = req.receiveHead(&head_buf) catch return null;
            if (resp.head.status != .ok) return null;
            var transfer: [4096]u8 = undefined;
            const rd = resp.reader(&transfer);
            var body: std.ArrayList(u8) = .empty;
            var buf: [4096]u8 = undefined;
            while (body.items.len < 1 << 16) {
                const got = rd.readSliceShort(&buf) catch return null;
                if (got == 0) break;
                body.appendSlice(self.a, buf[0..got]) catch return null;
            }
            const Answer = struct { type: u16 = 0, data: []const u8 = "" };
            const Doc = struct { Status: u16 = 0, Answer: []const Answer = &.{} };
            const doc = std.json.parseFromSliceLeaky(Doc, self.a, body.items, .{ .ignore_unknown_fields = true }) catch return null;
            // 1 is A and 28 AAAA; a CNAME chain ends in one of them.
            for (doc.Answer) |ans| {
                if (ans.type == 1 or ans.type == 28) return .{ .exists = true, .address = ans.data };
            }
            return .{ .exists = false };
        }
    };
};

const Probe = struct {
    a: Allocator,
    gpa: Allocator,
    io: std.Io,
    url: []const u8,
    want: []const u8,

    fn run(self: Probe) ?Result {
        return probe(self.a, self.gpa, self.io, self.url, self.want);
    }
};

/// `job.run()` in a child process, given up after `attempt_ms`: null when it
/// took too long or failed.
fn runTimed(comptime T: type, a: Allocator, job: anytype) ?T {
    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return job.run();
    const pid = sys.fork() catch {
        sys.close(pipe[0]);
        sys.close(pipe[1]);
        return job.run();
    };
    if (pid == 0) {
        sys.close(pipe[0]);
        const r = job.run() orelse linux.exit_group(1);
        const json = std.json.Stringify.valueAlloc(a, r, .{}) catch linux.exit_group(1);
        sys.writeAll(pipe[1], json) catch {};
        linux.exit_group(0);
    }
    sys.close(pipe[1]);
    defer sys.close(pipe[0]);
    var text: std.ArrayList(u8) = .empty;
    var buf: [1024]u8 = undefined;
    const start = sys.monoNs();
    var finished = false;
    while (true) {
        const elapsed: i64 = @intCast(@divFloor(sys.monoNs() - start, std.time.ns_per_ms));
        if (elapsed >= attempt_ms) break;
        var pfd = [1]linux.pollfd{.{ .fd = pipe[0], .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&pfd, 1, @intCast(attempt_ms - elapsed));
        if (linux.errno(rc) != .SUCCESS or rc == 0) continue;
        const got = sys.read(pipe[0], &buf) catch 0;
        if (got == 0) {
            finished = true;
            break;
        }
        text.appendSlice(a, buf[0..got]) catch break;
    }
    if (!finished) _ = linux.kill(pid, .KILL);
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
    if (!finished or text.items.len == 0) return null;
    return std.json.parseFromSliceLeaky(T, a, text.items, .{ .ignore_unknown_fields = true }) catch null;
}

fn probe(a: Allocator, gpa: Allocator, io: std.Io, url: []const u8, want: []const u8) Result {
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    const uri = std.Uri.parse(url) catch return .{ .status = .dns, .detail = "not a valid name" };
    var req = http.request(.GET, uri, .{
        .keep_alive = false,
        .headers = .{
            .accept_encoding = .omit,
            .user_agent = .{ .override = "pocketharbor-domain-check" },
        },
    }) catch |e| return failure(e);
    defer req.deinit();
    req.sendBodiless() catch |e| return failure(e);
    var head_buf: [16384]u8 = undefined;
    var resp = req.receiveHead(&head_buf) catch |e| return failure(e);
    const code: u16 = @intFromEnum(resp.head.status);
    var cloudflare = false;
    var headers = resp.head.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "server") and std.ascii.findIgnoreCase(h.value, "cloudflare") != null) cloudflare = true;
    }
    var transfer: [4096]u8 = undefined;
    const rd = resp.reader(&transfer);
    var body: [256]u8 = undefined;
    const len = rd.readSliceShort(&body) catch 0;
    if (code == 200 and std.mem.eql(u8, std.mem.trim(u8, body[0..len], " \r\n"), want)) return .{ .status = .active };
    if (cloudflare) {
        return .{ .status = .cloudflare, .detail = std.fmt.allocPrint(a, "Cloudflare answered with {d}", .{code}) catch "" };
    }
    return .{ .status = .elsewhere, .detail = std.fmt.allocPrint(a, "another server answered with {d}", .{code}) catch "" };
}

fn failure(e: anyerror) Result {
    const name = @errorName(e);
    const has = struct {
        fn f(text: []const u8, part: []const u8) bool {
            return std.mem.indexOf(u8, text, part) != null;
        }
    }.f;
    if (has(name, "UnknownHost") or has(name, "NameServer") or has(name, "HostLacks") or has(name, "Resolv") or has(name, "NoAddress")) {
        return .{ .status = .dns, .detail = "the name does not resolve" };
    }
    if (has(name, "Tls") or has(name, "Certificate")) {
        return .{ .status = .elsewhere, .detail = "a server answered with a certificate for another name" };
    }
    return .{ .status = .no_answer, .detail = name };
}

const t = std.testing;

test "names relative to their zone" {
    try t.expectEqualStrings("app", split("app.example.com").name);
    try t.expectEqualStrings("example.com", split("app.example.com").zone);
    try t.expectEqualStrings("@", split("example.com").name);
    try t.expectEqualStrings("api.v2", split("api.v2.example.com").name);
    try t.expectEqualStrings("@", split("example.co.uk").name);
    try t.expectEqualStrings("shop", split("shop.example.co.uk").name);
    try t.expectEqualStrings("example.co.uk", split("shop.example.co.uk").zone);
    try t.expectEqualStrings("*", split("*.example.com").name);
}

test "the record each setup needs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tunnel = try records(a, "app.example.com", .{ .tunnel = "6ff42ae2-765d-4adf-8112-31c55c1551ef" });
    try t.expectEqualStrings("CNAME", tunnel[0].type);
    try t.expectEqualStrings("app", tunnel[0].name);
    try t.expectEqualStrings("6ff42ae2-765d-4adf-8112-31c55c1551ef.cfargotunnel.com", tunnel[0].value);
    try t.expect(tunnel[0].proxied);
    const lan = try records(a, "example.com", .{ .lan = .{ 192, 168, 1, 20 } });
    try t.expectEqualStrings("A", lan[0].type);
    try t.expectEqualStrings("@", lan[0].name);
    try t.expectEqualStrings("192.168.1.20", lan[0].value);
    try t.expectEqual(@as(usize, 0), (try records(a, "example.com", .none)).len);
}

test "a wildcard is checked through a name it covers" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("pharbor-check.example.com", try probeHost(arena.allocator(), "*.example.com"));
    try t.expectEqualStrings("app.example.com", try probeHost(arena.allocator(), "app.example.com"));
}
