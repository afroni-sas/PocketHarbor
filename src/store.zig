//! What PocketHarbor remembers, under one data directory:
//!
//!   <root>/services/<name>.json   one service and its current deployment
//!   <root>/settings.json          base domain, catch-all service, proxy port
//!   <root>/routes.json            generated: what the proxy serves
//!   <root>/proxy.pid              lets a change reach the running proxy
//!   <root>/http/<name>.log        HTTP access log of a service

const std = @import("std");
const sys = @import("sys.zig");
const routes = @import("routes.zig");
const linux = sys.linux;
const Allocator = std.mem.Allocator;

pub const Service = struct {
    name: []const u8,
    image: []const u8 = "",
    /// The port the app listens on inside its container; 0 means detect it.
    port: u16 = 0,
    domains: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    /// Empty: a deployment is healthy as soon as its port accepts connections.
    health_path: []const u8 = "",
    sleep_after_s: u32 = 0,
    /// The container currently serving traffic.
    container: []const u8 = "",
    host_port: u16 = 0,
    asleep: bool = false,
    deployment: u32 = 0,
    deployed_at: i64 = 0,
};

pub const Settings = struct {
    /// With it, every service also answers at `<name>.<base_domain>`.
    base_domain: []const u8 = "",
    /// The service that answers for any hostname nothing else claims.
    default_service: []const u8 = "",
    proxy_port: u16 = 8080,
};

/// Names end up in hostnames and file paths.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 40 or name[0] == '-' or name[name.len - 1] == '-') return false;
    for (name) |ch| {
        if (!(ch >= 'a' and ch <= 'z') and !(ch >= '0' and ch <= '9') and ch != '-') return false;
    }
    return true;
}

pub fn validDomain(d: []const u8) bool {
    if (d.len == 0 or d.len > 253) return false;
    if (std.mem.eql(u8, d, "*")) return true;
    const host = if (std.mem.startsWith(u8, d, "*.")) d[2..] else d;
    if (std.mem.indexOfScalar(u8, host, '.') == null) return false;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |l| {
        if (l.len == 0 or l.len > 63 or l[0] == '-' or l[l.len - 1] == '-') return false;
        for (l) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
        }
    }
    return true;
}

pub const Store = struct {
    a: Allocator,
    root: []const u8,

    pub fn init(a: Allocator, root: []const u8) !Store {
        const self: Store = .{ .a = a, .root = root };
        for ([_][]const u8{ "services", "http" }) |d| try sys.mkdirP(self.path(d), 0o700);
        return self;
    }

    pub fn path(self: Store, rel: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel }) catch @panic("OOM");
    }

    fn servicePath(self: Store, name: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a, "{s}/services/{s}.json", .{ self.root, name }) catch @panic("OOM");
    }

    /// Serialises changes to services. Released by `unlock` or at exit.
    pub fn lock(self: Store) !i32 {
        const p = try sys.Path.of(self.path("lock"));
        var pz = p;
        const fd = try sys.open(pz.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_CLOEXEC, 0o600);
        const LOCK_EX = 2;
        _ = try sys.ck(linux.flock(fd, LOCK_EX));
        return fd;
    }

    pub fn unlock(_: Store, fd: i32) void {
        sys.close(fd);
    }

    pub fn exists(self: Store, name: []const u8) bool {
        var p = sys.Path.of(self.servicePath(name)) catch return false;
        return sys.exists(p.z());
    }

    pub fn load(self: Store, name: []const u8) !Service {
        const data = try sys.readFileAlloc(self.a, self.servicePath(name), 1 << 20);
        return std.json.parseFromSliceLeaky(Service, self.a, data, .{ .ignore_unknown_fields = true });
    }

    pub fn save(self: Store, svc: Service) !void {
        const data = try std.json.Stringify.valueAlloc(self.a, svc, .{ .whitespace = .indent_2 });
        try sys.writeFileAtomic(self.servicePath(svc.name), data, 0o600);
    }

    pub fn remove(self: Store, name: []const u8) void {
        var p = sys.Path.of(self.servicePath(name)) catch return;
        sys.unlink(p.z()) catch {};
    }

    pub fn list(self: Store) ![]Service {
        var out: std.ArrayList(Service) = .empty;
        var d = try sys.Path.of(self.path("services"));
        var it = try sys.DirIter.open_(d.z());
        defer it.deinit();
        while (try it.next()) |ent| {
            if (!std.mem.endsWith(u8, ent.name, ".json")) continue;
            const name = try self.a.dupe(u8, ent.name[0 .. ent.name.len - 5]);
            try out.append(self.a, self.load(name) catch continue);
        }
        std.mem.sort(Service, out.items, {}, struct {
            fn lt(_: void, x: Service, y: Service) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        return out.items;
    }

    pub fn settings(self: Store) Settings {
        const data = sys.readFileAlloc(self.a, self.path("settings.json"), 1 << 16) catch return .{};
        return std.json.parseFromSliceLeaky(Settings, self.a, data, .{ .ignore_unknown_fields = true }) catch .{};
    }

    pub fn saveSettings(self: Store, s: Settings) !void {
        const data = try std.json.Stringify.valueAlloc(self.a, s, .{ .whitespace = .indent_2 });
        try sys.writeFileAtomic(self.path("settings.json"), data, 0o600);
    }

    /// Every hostname a service answers for.
    pub fn hostnames(self: Store, svc: Service, s: Settings) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try out.appendSlice(self.a, svc.domains);
        if (s.base_domain.len > 0) {
            try out.append(self.a, try std.fmt.allocPrint(self.a, "{s}.{s}", .{ svc.name, s.base_domain }));
        }
        if (std.mem.eql(u8, s.default_service, svc.name)) try out.append(self.a, "*");
        return out.items;
    }

    /// Writes the table the proxy serves and tells the proxy. Also the signal
    /// that wakes requests parked behind a service that was starting.
    pub fn syncRoutes(self: Store) void {
        const services = self.list() catch return;
        const s = self.settings();
        var out: std.ArrayList(routes.Route) = .empty;
        for (services) |svc| {
            if (svc.container.len == 0) continue;
            const names = self.hostnames(svc, s) catch return;
            for (names) |host| {
                out.append(self.a, .{
                    .host = host,
                    .service = svc.name,
                    .port = svc.host_port,
                    .asleep = svc.asleep,
                    .sleep_after_s = svc.sleep_after_s,
                }) catch return;
            }
        }
        const data = std.json.Stringify.valueAlloc(self.a, routes.Document{ .routes = out.items }, .{}) catch return;
        sys.writeFileAtomic(self.path("routes.json"), data, 0o600) catch return;
        if (self.proxyPid()) |pid| _ = linux.kill(pid, .HUP);
    }

    pub fn proxyPid(self: Store) ?i32 {
        const data = sys.readFileAlloc(self.a, self.path("proxy.pid"), 64) catch return null;
        var it = std.mem.tokenizeAny(u8, data, " \n");
        const pid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
        const started = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        // A stale file must never get a signal sent to whoever has that pid now.
        return if (started != 0 and sys.sameProcess(pid, started)) pid else null;
    }

    pub fn writeProxyPid(self: Store) !void {
        const pid = linux.getpid();
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d} {d}\n", .{ pid, sys.procStart(pid) }) catch unreachable;
        try sys.writeFileAtomic(self.path("proxy.pid"), text, 0o600);
    }
};

const t = std.testing;

test "service names fit in a hostname" {
    try t.expect(validName("web"));
    try t.expect(validName("api-2"));
    try t.expect(!validName("-web"));
    try t.expect(!validName("web-"));
    try t.expect(!validName("Web"));
    try t.expect(!validName("a/b"));
    try t.expect(!validName(""));
}

test "domains are checked label by label" {
    try t.expect(validDomain("app.example.com"));
    try t.expect(validDomain("*.example.com"));
    try t.expect(validDomain("*"));
    try t.expect(!validDomain("nodot"));
    try t.expect(!validDomain("a..b"));
    try t.expect(!validDomain("-a.b"));
    try t.expect(!validDomain("a.b/c"));
}
