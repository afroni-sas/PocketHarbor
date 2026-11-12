//! What PocketHarbor remembers, under one data directory:
//!
//!   <root>/projects/<name>.json   a project and its environments
//!   <root>/services/<id>.json     one service and its current deployment
//!   <root>/deployments/<id>/      every attempt: <n>.json and <n>.log
//!   <root>/settings.json          base domain, catch-all service, proxy port
//!   <root>/routes.json            generated: what the proxy serves
//!   <root>/proxy.pid              lets a change reach the running proxy
//!   <root>/http/<id>.log          HTTP access log of a service

const std = @import("std");
const sys = @import("sys.zig");
const routes = @import("routes.zig");
const linux = sys.linux;
const Allocator = std.mem.Allocator;

pub const Volume = struct { name: []const u8, mount: []const u8 };

pub const Project = struct {
    name: []const u8,
    environments: []const []const u8 = &.{"production"},
    created_at: i64 = 0,

    pub fn hasEnvironment(self: Project, name: []const u8) bool {
        for (self.environments) |e| if (std.mem.eql(u8, e, name)) return true;
        return false;
    }
};

/// One service in one environment of a project.
pub const Service = struct {
    project: []const u8 = default_project,
    environment: []const u8 = default_environment,
    name: []const u8,
    image: []const u8 = "",
    /// "owner/name" on GitHub, built on each deployment. Empty for an image.
    repo: []const u8 = "",
    branch: []const u8 = "main",
    /// The directory of the repository to build, for monorepos.
    root_dir: []const u8 = "",
    /// Deploy on every push to the branch.
    auto_deploy: bool = true,
    build_command: []const u8 = "",
    start_command: []const u8 = "",
    /// Runs in the new version before it takes traffic, for migrations.
    pre_deploy: []const u8 = "",
    /// The port the app listens on inside its container; 0 means detect it.
    port: u16 = 0,
    domains: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    /// Empty: a deployment is healthy as soon as its port accepts connections.
    health_path: []const u8 = "",
    /// How long a deployment has to become healthy; 0 is the default, 180 s.
    health_timeout_s: u32 = 0,
    /// What happens when the app exits, as Railway names it: "on-failure"
    /// (restarted up to `restart_retries` times), "always" or "never".
    restart_policy: []const u8 = "on-failure",
    restart_retries: u32 = 10,
    sleep_after_s: u32 = 0,
    volumes: []const Volume = &.{},
    /// "daily", "weekly" or empty: when its volumes are backed up.
    backup_schedule: []const u8 = "",
    /// A cron schedule, in UTC. Such a service has no long-running container:
    /// each run starts the active deployment's image and waits for it to end.
    cron: []const u8 = "",
    /// Where its card sits on the canvas.
    x: i32 = 0,
    y: i32 = 0,
    /// The container currently serving traffic.
    container: []const u8 = "",
    host_port: u16 = 0,
    asleep: bool = false,
    deployment: u32 = 0,
    deployed_at: i64 = 0,
};

/// One attempt to ship a version of a service.
pub const Deployment = struct {
    number: u32,
    /// "deploying", "active", "failed" or "removed".
    status: []const u8 = "deploying",
    image: []const u8 = "",
    /// What asked for it: "cli", "api", "webhook", "redeploy" or "rollback".
    trigger: []const u8 = "cli",
    /// For a build from GitHub: the commit, shortened, and its title.
    commit: []const u8 = "",
    message: []const u8 = "",
    container: []const u8 = "",
    reason: []const u8 = "",
    created_at: i64 = 0,
    finished_at: i64 = 0,
};

pub const default_project = "default";
pub const default_environment = "production";

pub const Settings = struct {
    /// With it, every service also answers at `<name>.<base_domain>`.
    base_domain: []const u8 = "",
    /// The service that answers for any hostname nothing else claims.
    default_service: []const u8 = "",
    proxy_port: u16 = 8080,
    /// The panel answers here, and at the phone's own address.
    panel_domain: []const u8 = "",
    panel_port: u16 = 8090,
    /// Encrypted. Lets builds read private repositories.
    github_token: []const u8 = "",
    /// Encrypted. GitHub signs webhook deliveries with it.
    webhook_secret: []const u8 = "",
    /// What /__pharbor/check answers, so that a domain check knows it
    /// reached this installation and not another server.
    check_id: []const u8 = "",
    /// The Cloudflare tunnel started with a token, for the DNS records to show.
    tunnel_id: []const u8 = "",
    /// Encrypted. With it PocketHarbor writes the tunnel's routes and the
    /// DNS records of the public names itself.
    cloudflare_token: []const u8 = "",
    cloudflare_account: []const u8 = "",
    /// The zone that serves domains whose DNS is elsewhere, through
    /// Cloudflare for SaaS; empty for none.
    cloudflare_saas_zone: []const u8 = "",
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
        for ([_][]const u8{ "services", "projects", "deployments", "http" }) |d| try sys.mkdirP(self.path(d), 0o700);
        return self;
    }

    pub fn path(self: Store, rel: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel }) catch @panic("OOM");
    }

    /// `project.environment.name`: unique, and safe in a file name.
    pub fn idOf(self: Store, svc: Service) []const u8 {
        return self.idFrom(svc.project, svc.environment, svc.name);
    }

    pub fn idFrom(self: Store, project: []const u8, environment: []const u8, name: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a, "{s}.{s}.{s}", .{ project, environment, name }) catch @panic("OOM");
    }

    fn servicePath(self: Store, id: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a, "{s}/services/{s}.json", .{ self.root, id }) catch @panic("OOM");
    }

    fn projectPath(self: Store, name: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a, "{s}/projects/{s}.json", .{ self.root, name }) catch @panic("OOM");
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

    pub fn exists(self: Store, id: []const u8) bool {
        var p = sys.Path.of(self.servicePath(id)) catch return false;
        return sys.exists(p.z());
    }

    pub fn load(self: Store, id: []const u8) !Service {
        const data = try sys.readFileAlloc(self.a, self.servicePath(id), 1 << 20);
        return std.json.parseFromSliceLeaky(Service, self.a, data, .{ .ignore_unknown_fields = true });
    }

    pub fn save(self: Store, svc: Service) !void {
        const data = try std.json.Stringify.valueAlloc(self.a, svc, .{ .whitespace = .indent_2 });
        try sys.writeFileAtomic(self.servicePath(self.idOf(svc)), data, 0o600);
    }

    pub fn remove(self: Store, id: []const u8) void {
        var p = sys.Path.of(self.servicePath(id)) catch return;
        sys.unlink(p.z()) catch {};
        sys.rmrf(self.deploymentDir(id)) catch {};
    }

    pub fn listIn(self: Store, project: []const u8, environment: []const u8) ![]Service {
        var out: std.ArrayList(Service) = .empty;
        for (try self.list()) |svc| {
            if (std.mem.eql(u8, svc.project, project) and std.mem.eql(u8, svc.environment, environment)) {
                try out.append(self.a, svc);
            }
        }
        return out.items;
    }

    pub fn projectExists(self: Store, name: []const u8) bool {
        var p = sys.Path.of(self.projectPath(name)) catch return false;
        return sys.exists(p.z());
    }

    pub fn loadProject(self: Store, name: []const u8) !Project {
        const data = try sys.readFileAlloc(self.a, self.projectPath(name), 1 << 20);
        return std.json.parseFromSliceLeaky(Project, self.a, data, .{ .ignore_unknown_fields = true });
    }

    pub fn saveProject(self: Store, p: Project) !void {
        const data = try std.json.Stringify.valueAlloc(self.a, p, .{ .whitespace = .indent_2 });
        try sys.writeFileAtomic(self.projectPath(p.name), data, 0o600);
    }

    pub fn removeProject(self: Store, name: []const u8) void {
        var p = sys.Path.of(self.projectPath(name)) catch return;
        sys.unlink(p.z()) catch {};
    }

    pub fn listProjects(self: Store) ![]Project {
        var out: std.ArrayList(Project) = .empty;
        var d = try sys.Path.of(self.path("projects"));
        var it = try sys.DirIter.open_(d.z());
        defer it.deinit();
        while (try it.next()) |ent| {
            if (!std.mem.endsWith(u8, ent.name, ".json")) continue;
            const name = try self.a.dupe(u8, ent.name[0 .. ent.name.len - 5]);
            try out.append(self.a, self.loadProject(name) catch continue);
        }
        std.mem.sort(Project, out.items, {}, struct {
            fn lt(_: void, x: Project, y: Project) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        return out.items;
    }

    /// Creates a project or environment the first time it is used.
    pub fn ensureEnvironment(self: Store, project: []const u8, environment: []const u8) !void {
        if (!self.projectExists(project)) {
            try self.saveProject(.{
                .name = project,
                .environments = &.{environment},
                .created_at = @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s)),
            });
            return;
        }
        var p = try self.loadProject(project);
        for (p.environments) |e| {
            if (std.mem.eql(u8, e, environment)) return;
        }
        var envs: std.ArrayList([]const u8) = .empty;
        try envs.appendSlice(self.a, p.environments);
        try envs.append(self.a, environment);
        p.environments = envs.items;
        try self.saveProject(p);
    }

    pub fn deploymentDir(self: Store, id: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a, "{s}/deployments/{s}", .{ self.root, id }) catch @panic("OOM");
    }

    pub fn deploymentLog(self: Store, id: []const u8, number: u32) []const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{d}.log", .{ self.deploymentDir(id), number }) catch @panic("OOM");
    }

    pub fn saveDeployment(self: Store, id: []const u8, d: Deployment) !void {
        try sys.mkdirP(self.deploymentDir(id), 0o700);
        const data = try std.json.Stringify.valueAlloc(self.a, d, .{ .whitespace = .indent_2 });
        const file = try std.fmt.allocPrint(self.a, "{s}/{d}.json", .{ self.deploymentDir(id), d.number });
        try sys.writeFileAtomic(file, data, 0o600);
    }

    pub fn loadDeployment(self: Store, id: []const u8, number: u32) !Deployment {
        const file = try std.fmt.allocPrint(self.a, "{s}/{d}.json", .{ self.deploymentDir(id), number });
        const data = try sys.readFileAlloc(self.a, file, 1 << 20);
        return std.json.parseFromSliceLeaky(Deployment, self.a, data, .{ .ignore_unknown_fields = true });
    }

    /// Newest first.
    pub fn listDeployments(self: Store, id: []const u8) ![]Deployment {
        var out: std.ArrayList(Deployment) = .empty;
        var d = sys.Path.of(self.deploymentDir(id)) catch return out.items;
        var it = sys.DirIter.open_(d.z()) catch return out.items;
        defer it.deinit();
        while (try it.next()) |ent| {
            if (!std.mem.endsWith(u8, ent.name, ".json")) continue;
            const n = std.fmt.parseInt(u32, ent.name[0 .. ent.name.len - 5], 10) catch continue;
            try out.append(self.a, self.loadDeployment(id, n) catch continue);
        }
        std.mem.sort(Deployment, out.items, {}, struct {
            fn lt(_: void, x: Deployment, y: Deployment) bool {
                return x.number > y.number;
            }
        }.lt);
        return out.items;
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

    /// What a service is called under the base domain. The default project
    /// and production keep the short forms.
    pub fn publicLabel(self: Store, svc: Service) []const u8 {
        const in_default = std.mem.eql(u8, svc.project, default_project);
        const in_production = std.mem.eql(u8, svc.environment, default_environment);
        return (if (in_default and in_production)
            self.a.dupe(u8, svc.name)
        else if (in_default)
            std.fmt.allocPrint(self.a, "{s}-{s}", .{ svc.name, svc.environment })
        else if (in_production)
            std.fmt.allocPrint(self.a, "{s}-{s}", .{ svc.project, svc.name })
        else
            std.fmt.allocPrint(self.a, "{s}-{s}-{s}", .{ svc.project, svc.name, svc.environment })) catch @panic("OOM");
    }

    /// Every hostname a service answers for.
    pub fn hostnames(self: Store, svc: Service, s: Settings) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try out.appendSlice(self.a, svc.domains);
        if (s.base_domain.len > 0) {
            try out.append(self.a, try std.fmt.allocPrint(self.a, "{s}.{s}", .{ self.publicLabel(svc), s.base_domain }));
        }
        if (std.mem.eql(u8, s.default_service, self.idOf(svc))) try out.append(self.a, "*");
        return out.items;
    }

    /// The id /__pharbor/check answers, made on first use.
    pub fn checkId(self: Store) ![]const u8 {
        var s = self.settings();
        if (s.check_id.len > 0) return s.check_id;
        const id = try self.a.alloc(u8, 32);
        sys.randomId(id);
        s.check_id = id;
        try self.saveSettings(s);
        return id;
    }

    /// What already answers for `host`: a service's name, or "the dashboard".
    /// `except` is the id of the service being changed.
    pub fn domainOwner(self: Store, s: Settings, host: []const u8, except: []const u8) !?[]const u8 {
        if (s.panel_domain.len > 0 and std.ascii.eqlIgnoreCase(s.panel_domain, host)) return "the dashboard";
        for (try self.list()) |svc| {
            if (std.mem.eql(u8, self.idOf(svc), except)) continue;
            for (try self.hostnames(svc, s)) |h| {
                if (!std.mem.eql(u8, h, "*") and std.ascii.eqlIgnoreCase(h, host)) return svc.name;
            }
        }
        return null;
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
                    .service = self.idOf(svc),
                    .port = svc.host_port,
                    .asleep = svc.asleep,
                    .sleep_after_s = svc.sleep_after_s,
                }) catch return;
            }
        }
        if (s.panel_domain.len > 0) {
            out.append(self.a, .{ .host = s.panel_domain, .service = routes.panel_service, .port = s.panel_port }) catch return;
        }
        const doc: routes.Document = .{ .routes = out.items, .panel_port = s.panel_port };
        const data = std.json.Stringify.valueAlloc(self.a, doc, .{}) catch return;
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

test "the default project keeps short public names" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const store: Store = .{ .a = arena.allocator(), .root = "/x" };
    try t.expectEqualStrings("web", store.publicLabel(.{ .name = "web" }));
    try t.expectEqualStrings("web-staging", store.publicLabel(.{ .name = "web", .environment = "staging" }));
    try t.expectEqualStrings("shop-web", store.publicLabel(.{ .name = "web", .project = "shop" }));
    try t.expectEqualStrings("shop-web-staging", store.publicLabel(.{ .name = "web", .project = "shop", .environment = "staging" }));
    try t.expectEqualStrings("shop.staging.web", store.idOf(.{ .name = "web", .project = "shop", .environment = "staging" }));
}

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
