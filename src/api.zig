//! The panel's JSON API. Everything the web interface does goes through here,
//! and an API token gives scripts the same access.

const std = @import("std");
const sys = @import("sys.zig");
const httpd = @import("httpd.zig");
const engine = @import("engine.zig");
const auth_mod = @import("auth.zig");
const crypto = @import("crypto.zig");
const deploy = @import("deploy.zig");
const store_mod = @import("store.zig");
const vars_mod = @import("vars.zig");
const github = @import("github.zig");
const backup = @import("backup.zig");
const cron = @import("cron.zig");
const scheduler = @import("scheduler.zig");
const metrics = @import("metrics.zig");
const ws = @import("ws.zig");
const terminal = @import("terminal.zig");
const alerts = @import("alerts.zig");
const templates = @import("templates.zig");
const Store = store_mod.Store;
const Service = store_mod.Service;
const Request = httpd.Request;
const Response = httpd.Response;
const Auth = auth_mod.Auth;
const linux = sys.linux;
const Allocator = std.mem.Allocator;

/// Shared by every request thread. Each request makes its own Store and
/// Engine on its own arena, from these.
pub const Panel = struct {
    root: []const u8,
    io: std.Io,
    key: crypto.Key,
    pdock: [:0]const u8,
    envp: engine.Envp,
    throttle: auth_mod.Throttle = .{},
    /// The web interface, when built in.
    assets: []const Asset = &.{},
};

pub const Asset = struct { path: []const u8, type: []const u8, body: []const u8 };

const Ctx = struct {
    panel: *Panel,
    req: *Request,
    res: *Response,
    a: Allocator,
    store: Store,
    auth: Auth,
    eng: engine.Engine,
    vars: vars_mod.Vars,
    who: auth_mod.Who = .{},
};

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn nowS() i64 {
    return @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s));
}

pub fn handle(raw: *anyopaque, req: *Request, res: *Response) void {
    const panel: *Panel = @ptrCast(@alignCast(raw));
    const store: Store = .{ .a = req.a, .root = panel.root };
    var c: Ctx = .{
        .panel = panel,
        .req = req,
        .res = res,
        .a = req.a,
        .store = store,
        .auth = .{ .store = store, .io = panel.io, .key = panel.key },
        .eng = .{ .a = req.a, .bin = panel.pdock, .envp = panel.envp },
        .vars = .{ .store = store, .key = panel.key },
    };
    if (std.mem.eql(u8, req.path, "/__pharbor/webhooks/github")) {
        return webhook(&c) catch |e| res.fail(500, @errorName(e));
    }
    if (!std.mem.startsWith(u8, req.path, "/api/")) return serveAsset(&c);
    route(&c) catch |e| {
        if (!res.sent) res.fail(500, @errorName(e));
    };
}

fn serveAsset(c: *Ctx) void {
    const path = if (eql(c.req.path, "/")) "/index.html" else c.req.path;
    for (c.panel.assets) |asset| {
        if (eql(asset.path, path)) {
            c.res.addHeader("Cache-Control", if (std.mem.startsWith(u8, path, "/assets/")) "public, max-age=31536000, immutable" else "no-cache");
            return c.res.send(200, asset.type, asset.body);
        }
    }
    // The interface routes on the client, so unknown paths get the app.
    for (c.panel.assets) |asset| {
        if (eql(asset.path, "/index.html")) {
            c.res.addHeader("Cache-Control", "no-cache");
            return c.res.send(200, asset.type, asset.body);
        }
    }
    c.res.send(200, "text/html; charset=utf-8", "<!doctype html><title>PocketHarbor</title><p>The API is at /api/. This build has no web interface.");
}

/// Splits "/api/a/b/c" into its parts after "api".
fn segments(a: Allocator, path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path[5..], '/');
    while (it.next()) |s| try out.append(a, s);
    return out.items;
}

fn method(c: *Ctx, m: []const u8) bool {
    return eql(c.req.method, m);
}

/// Browsers send cookies along with cross-site requests; tokens do not.
/// A change made with a cookie must come from a page of this origin.
fn sameOrigin(c: *Ctx) bool {
    if (method(c, "GET") or method(c, "HEAD")) return true;
    // Another site can send a POST, but only a "simple" one, which cannot be
    // JSON. PATCH and DELETE would need a preflight, which is never granted.
    if (method(c, "POST")) {
        const ctype = c.req.header("content-type") orelse "";
        if (!std.mem.startsWith(u8, ctype, "application/json")) return false;
    }
    const origin = c.req.header("origin") orelse return true;
    const host = c.req.header("x-forwarded-host") orelse c.req.header("host") orelse return false;
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return false;
    return eql(origin[scheme_end + 3 ..], host);
}

fn authenticate(c: *Ctx) bool {
    if (c.req.header("authorization")) |h| {
        if (std.mem.startsWith(u8, h, "Bearer ")) {
            if (c.auth.checkToken(h[7..])) |tk| {
                c.who = .{ .token = tk.name };
                return true;
            }
            return false;
        }
    }
    const token = c.req.cookie(auth_mod.session_cookie) orelse return false;
    const user = c.auth.sessionUser(token) orelse return false;
    if (!sameOrigin(c)) return false;
    c.who = .{ .user = user };
    return true;
}

fn setSessionCookie(c: *Ctx, token: []const u8, max_age: i64) void {
    const v = std.fmt.allocPrint(c.a, "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}{s}", .{
        auth_mod.session_cookie, token, max_age, if (c.req.secure()) "; Secure" else "",
    }) catch return;
    c.res.addHeader("Set-Cookie", v);
}

fn route(c: *Ctx) !void {
    const seg = try segments(c.a, c.req.path);
    if (seg.len == 0) return c.res.fail(404, "not found");

    // Reachable without signing in.
    if (eql(seg[0], "setup") and method(c, "POST")) return setup(c);
    if (eql(seg[0], "login") and method(c, "POST")) return login(c);
    if (eql(seg[0], "logout") and method(c, "POST")) return logout(c);
    if (eql(seg[0], "status") and method(c, "GET")) {
        return c.res.json(200, .{ .setup_needed = c.auth.users().len == 0, .version = "0.1.0" });
    }

    if (!authenticate(c)) return c.res.fail(401, "sign in first");

    if (eql(seg[0], "me")) return me(c, seg[1..]);
    if (eql(seg[0], "users")) return users(c, seg[1..]);
    if (eql(seg[0], "tokens")) return tokens(c, seg[1..]);
    if (eql(seg[0], "projects")) return projects(c, seg[1..]);
    if (eql(seg[0], "services")) return services(c, seg[1..]);
    if (eql(seg[0], "settings")) return settings(c);
    if (eql(seg[0], "github")) return githubSettings(c, seg[1..]);
    if (eql(seg[0], "registries")) return registries(c, seg[1..]);
    if (eql(seg[0], "tunnel")) return tunnelApi(c, seg[1..]);
    if (eql(seg[0], "alerts")) return alertsApi(c, seg[1..]);
    if (eql(seg[0], "templates")) return templatesApi(c, seg[1..]);
    c.res.fail(404, "not found");
}

fn setup(c: *Ctx) !void {
    if (c.auth.users().len > 0) return c.res.fail(409, "already set up");
    const body = c.req.json(struct { email: []const u8, password: []const u8 }) catch return c.res.fail(400, "send email and password");
    const user = c.auth.addUser(body.email, body.password) catch |e| return c.res.fail(400, explain(e));
    setSessionCookie(c, try c.auth.createSession(user), auth_mod.session_days * 86400);
    c.res.json(201, userView(user));
}

fn explain(e: anyerror) []const u8 {
    return switch (e) {
        error.PasswordTooShort => "the password needs at least 8 characters",
        error.BadEmail => "that is not an email address",
        error.UserExists => "an account with this email already exists",
        error.BadCredentials => "wrong email or password",
        error.CodeRequired => "enter the code from your authenticator app",
        error.BadCode => "that code is not valid",
        else => @errorName(e),
    };
}

fn login(c: *Ctx) !void {
    const ip = c.req.clientIp();
    if (c.panel.throttle.blocked(ip)) return c.res.fail(429, "too many attempts, wait a few minutes");
    const body = c.req.json(struct { email: []const u8, password: []const u8, code: ?[]const u8 = null }) catch return c.res.fail(400, "send email and password");
    const user = c.auth.login(body.email, body.password, body.code) catch |e| {
        if (e == error.CodeRequired) return c.res.json(401, .{ .@"error" = explain(e), .code_required = true });
        c.panel.throttle.failed(ip);
        return c.res.fail(401, explain(e));
    };
    c.panel.throttle.succeeded(ip);
    setSessionCookie(c, try c.auth.createSession(user), auth_mod.session_days * 86400);
    c.res.json(200, userView(user));
}

fn logout(c: *Ctx) !void {
    if (c.req.cookie(auth_mod.session_cookie)) |t| c.auth.endSession(t);
    setSessionCookie(c, "", 0);
    c.res.json(200, .{ .ok = true });
}

fn userView(u: auth_mod.User) struct { id: []const u8, email: []const u8, totp_enabled: bool, created_at: i64 } {
    return .{ .id = u.id, .email = u.email, .totp_enabled = u.totp_enabled, .created_at = u.created_at };
}

fn me(c: *Ctx, seg: []const []const u8) !void {
    const user = c.who.user orelse {
        if (seg.len == 0) return c.res.json(200, .{ .token = c.who.token });
        return c.res.fail(403, "only for a signed-in user");
    };
    if (seg.len == 0) return c.res.json(200, userView(user));
    if (eql(seg[0], "password") and method(c, "POST")) {
        const body = c.req.json(struct { current: []const u8, new: []const u8 }) catch return c.res.fail(400, "send current and new");
        _ = c.auth.login(user.email, body.current, null) catch |e| {
            if (e != error.CodeRequired) return c.res.fail(403, "the current password is wrong");
        };
        if (body.new.len < 8) return c.res.fail(400, explain(error.PasswordTooShort));
        var updated = user;
        updated.password = try c.auth.hashPassword(body.new);
        try c.auth.updateUser(updated);
        c.auth.endAllSessions(user.id);
        setSessionCookie(c, try c.auth.createSession(updated), auth_mod.session_days * 86400);
        return c.res.json(200, .{ .ok = true });
    }
    if (eql(seg[0], "2fa") and seg.len == 2) {
        if (eql(seg[1], "setup") and method(c, "POST")) {
            const secret = try c.auth.beginTotp(user);
            const uri = try std.fmt.allocPrint(c.a, "otpauth://totp/PocketHarbor:{s}?secret={s}&issuer=PocketHarbor", .{ user.email, secret });
            return c.res.json(200, .{ .secret = secret, .uri = uri });
        }
        if (eql(seg[1], "enable") and method(c, "POST")) {
            const body = c.req.json(struct { code: []const u8 }) catch return c.res.fail(400, "send code");
            c.auth.enableTotp(user, body.code) catch |e| return c.res.fail(400, explain(e));
            return c.res.json(200, .{ .ok = true });
        }
        if (eql(seg[1], "disable") and method(c, "POST")) {
            const body = c.req.json(struct { code: []const u8 }) catch return c.res.fail(400, "send code");
            _ = c.auth.verifyCode(user, body.code) catch |e| return c.res.fail(400, explain(e));
            try c.auth.disableTotp(user);
            return c.res.json(200, .{ .ok = true });
        }
    }
    c.res.fail(404, "not found");
}

fn users(c: *Ctx, seg: []const []const u8) !void {
    if (seg.len == 0 and method(c, "GET")) {
        var out: std.ArrayList(@TypeOf(userView(undefined))) = .empty;
        for (c.auth.users()) |u| try out.append(c.a, userView(u));
        return c.res.json(200, out.items);
    }
    if (seg.len == 0 and method(c, "POST")) {
        const body = c.req.json(struct { email: []const u8, password: []const u8 }) catch return c.res.fail(400, "send email and password");
        const user = c.auth.addUser(body.email, body.password) catch |e| return c.res.fail(400, explain(e));
        return c.res.json(201, userView(user));
    }
    if (seg.len == 1 and method(c, "DELETE")) {
        if (c.auth.users().len <= 1) return c.res.fail(409, "the last account cannot be removed");
        try c.auth.removeUser(seg[0]);
        c.auth.endAllSessions(seg[0]);
        return c.res.json(200, .{ .ok = true });
    }
    c.res.fail(404, "not found");
}

fn tokens(c: *Ctx, seg: []const []const u8) !void {
    const View = struct { id: []const u8, name: []const u8, hint: []const u8, created_at: i64 };
    if (seg.len == 0 and method(c, "GET")) {
        var out: std.ArrayList(View) = .empty;
        for (c.auth.tokens()) |t| try out.append(c.a, .{ .id = t.id, .name = t.name, .hint = t.hint, .created_at = t.created_at });
        return c.res.json(200, out.items);
    }
    if (seg.len == 0 and method(c, "POST")) {
        const body = c.req.json(struct { name: []const u8 }) catch return c.res.fail(400, "send name");
        const made = try c.auth.createToken(body.name);
        return c.res.json(201, .{ .id = made.info.id, .name = made.info.name, .token = made.token });
    }
    if (seg.len == 1 and method(c, "DELETE")) {
        if (!try c.auth.removeToken(seg[0])) return c.res.fail(404, "no such token");
        return c.res.json(200, .{ .ok = true });
    }
    c.res.fail(404, "not found");
}

const DeploymentSummary = struct { number: u32, status: []const u8, trigger: []const u8, commit: []const u8, message: []const u8, image: []const u8, created_at: i64 };

const ServiceView = struct {
    latest: ?DeploymentSummary,
    id: []const u8,
    project: []const u8,
    environment: []const u8,
    name: []const u8,
    image: []const u8,
    repo: []const u8,
    branch: []const u8,
    root_dir: []const u8,
    auto_deploy: bool,
    build_command: []const u8,
    start_command: []const u8,
    pre_deploy: []const u8,
    volumes: []const store_mod.Volume,
    backup_schedule: []const u8,
    cron: []const u8,
    last_run: ?scheduler.LastRun,
    port: u16,
    domains: []const []const u8,
    hostnames: []const []const u8,
    health_path: []const u8,
    sleep_after_s: u32,
    status: []const u8,
    deployment: u32,
    deployed_at: i64,
    x: i32,
    y: i32,
};

fn serviceView(c: *Ctx, svc: Service) !ServiceView {
    const info = if (svc.container.len > 0) c.eng.inspect(svc.container) else null;
    const status: []const u8 = if (svc.cron.len > 0 and svc.deployment > 0)
        "scheduled"
    else if (svc.asleep)
        "asleep"
    else if (info) |i|
        i.status
    else if (svc.deployment > 0)
        "failed"
    else
        "new";
    var latest: ?DeploymentSummary = null;
    if (svc.deployment > 0) {
        if (c.store.listDeployments(c.store.idOf(svc))) |all| {
            if (all.len > 0) {
                const d = all[0];
                latest = .{ .number = d.number, .status = d.status, .trigger = d.trigger, .commit = d.commit, .message = d.message, .image = d.image, .created_at = d.created_at };
            }
        } else |_| {}
    }
    return .{
        .latest = latest,
        .id = c.store.idOf(svc),
        .project = svc.project,
        .environment = svc.environment,
        .name = svc.name,
        .image = svc.image,
        .repo = svc.repo,
        .branch = svc.branch,
        .root_dir = svc.root_dir,
        .auto_deploy = svc.auto_deploy,
        .build_command = svc.build_command,
        .start_command = svc.start_command,
        .pre_deploy = svc.pre_deploy,
        .volumes = svc.volumes,
        .backup_schedule = svc.backup_schedule,
        .cron = svc.cron,
        .last_run = if (svc.cron.len > 0) scheduler.lastRun(c.store, c.store.idOf(svc)) else null,
        .port = svc.port,
        .domains = svc.domains,
        .hostnames = try c.store.hostnames(svc, c.store.settings()),
        .health_path = svc.health_path,
        .sleep_after_s = svc.sleep_after_s,
        .status = status,
        .deployment = svc.deployment,
        .deployed_at = svc.deployed_at,
        .x = svc.x,
        .y = svc.y,
    };
}

fn validName(name: []const u8) bool {
    return store_mod.validName(name);
}

fn projects(c: *Ctx, seg: []const []const u8) !void {
    if (seg.len == 0 and method(c, "GET")) {
        const View = struct { name: []const u8, environments: []const []const u8, created_at: i64, services: usize, online: usize };
        var out: std.ArrayList(View) = .empty;
        const all = try c.store.list();
        for (try c.store.listProjects()) |p| {
            var count: usize = 0;
            var online: usize = 0;
            for (all) |svc| {
                if (!eql(svc.project, p.name) or !eql(svc.environment, store_mod.default_environment)) continue;
                count += 1;
                // A cron service between runs is as healthy as it gets.
                if (svc.asleep or (svc.cron.len > 0 and svc.deployment > 0)) {
                    online += 1;
                } else if (svc.container.len > 0) {
                    if (c.eng.inspect(svc.container)) |i| {
                        if (i.running()) online += 1;
                    }
                }
            }
            try out.append(c.a, .{ .name = p.name, .environments = p.environments, .created_at = p.created_at, .services = count, .online = online });
        }
        return c.res.json(200, out.items);
    }
    if (seg.len == 0 and method(c, "POST")) {
        const body = c.req.json(struct { name: []const u8 }) catch return c.res.fail(400, "send name");
        if (!validName(body.name)) return c.res.fail(400, "use a-z, 0-9 and -");
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        if (c.store.projectExists(body.name)) return c.res.fail(409, "a project with this name exists");
        try c.store.ensureEnvironment(body.name, store_mod.default_environment);
        return c.res.json(201, try c.store.loadProject(body.name));
    }
    if (seg.len == 0) return c.res.fail(405, "method not allowed");
    const name = seg[0];
    if (!c.store.projectExists(name)) return c.res.fail(404, "no such project");

    if (seg.len == 1 and method(c, "GET")) return c.res.json(200, try c.store.loadProject(name));
    if (seg.len == 1 and method(c, "DELETE")) {
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        for (try c.store.list()) |svc| {
            if (eql(svc.project, name)) deploy.forget(c.store, &c.eng, c.vars, svc);
        }
        for ((try c.store.loadProject(name)).environments) |e| c.vars.dropEnvironment(name, e);
        c.store.removeProject(name);
        c.store.syncRoutes();
        return c.res.json(200, .{ .ok = true });
    }
    if (seg.len == 2 and eql(seg[1], "environments") and method(c, "POST")) {
        const body = c.req.json(struct { name: []const u8, from: []const u8 = store_mod.default_environment }) catch return c.res.fail(400, "send name");
        if (!validName(body.name)) return c.res.fail(400, "use a-z, 0-9 and -");
        const copied = try deploy.duplicateEnvironment(c.store, c.vars, name, body.from, body.name);
        return c.res.json(201, .{ .name = body.name, .copied = copied });
    }
    if (seg.len == 4 and eql(seg[1], "environments") and eql(seg[3], "logs") and method(c, "GET")) {
        return environmentLogs(c, name, seg[2]);
    }
    if (seg.len == 4 and eql(seg[1], "environments") and eql(seg[3], "edges") and method(c, "GET")) {
        return c.res.json(200, try edges(c, name, seg[2]));
    }
    if (seg.len == 4 and eql(seg[1], "environments") and eql(seg[3], "variables")) {
        if (!(try c.store.loadProject(name)).hasEnvironment(seg[2])) return c.res.fail(404, "no such environment");
        return variables(c, name, seg[2], null, seg[4..]);
    }
    if (seg.len == 5 and eql(seg[1], "environments") and eql(seg[3], "variables")) {
        return variables(c, name, seg[2], null, seg[4..]);
    }
    if (seg.len == 3 and eql(seg[1], "environments") and method(c, "DELETE")) {
        const env = seg[2];
        if (eql(env, store_mod.default_environment)) return c.res.fail(409, "production cannot be removed");
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        for (try c.store.listIn(name, env)) |svc| deploy.forget(c.store, &c.eng, c.vars, svc);
        c.vars.dropEnvironment(name, env);
        var p = try c.store.loadProject(name);
        var kept: std.ArrayList([]const u8) = .empty;
        for (p.environments) |e| {
            if (!eql(e, env)) try kept.append(c.a, e);
        }
        p.environments = kept.items;
        try c.store.saveProject(p);
        c.store.syncRoutes();
        return c.res.json(200, .{ .ok = true });
    }
    c.res.fail(404, "not found");
}

const ServiceInput = struct {
    project: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    name: ?[]const u8 = null,
    image: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    root_dir: ?[]const u8 = null,
    auto_deploy: ?bool = null,
    build_command: ?[]const u8 = null,
    start_command: ?[]const u8 = null,
    pre_deploy: ?[]const u8 = null,
    volumes: ?[]const store_mod.Volume = null,
    backup_schedule: ?[]const u8 = null,
    cron: ?[]const u8 = null,
    port: ?u16 = null,
    domains: ?[]const []const u8 = null,
    env: ?[]const []const u8 = null,
    health_path: ?[]const u8 = null,
    sleep_after_s: ?u32 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    deploy: bool = false,
};

fn applyInput(svc: *Service, in: ServiceInput) !void {
    if (in.image) |v| {
        svc.image = v;
        if (v.len > 0) svc.repo = "";
    }
    if (in.repo) |v| {
        svc.repo = if (v.len == 0) "" else github.normalizeRepo(v) orelse return error.BadRepo;
        if (svc.repo.len > 0) svc.image = "";
    }
    if (in.branch) |v| svc.branch = v;
    if (in.root_dir) |v| {
        if (std.mem.indexOf(u8, v, "..") != null) return error.BadRootDir;
        svc.root_dir = v;
    }
    if (in.auto_deploy) |v| svc.auto_deploy = v;
    if (in.build_command) |v| svc.build_command = v;
    if (in.start_command) |v| svc.start_command = v;
    if (in.pre_deploy) |v| svc.pre_deploy = v;
    if (in.volumes) |list| {
        for (list) |v| {
            if (!backup.validMount(v.mount) or !store_mod.validName(v.name)) return error.BadVolume;
        }
        svc.volumes = list;
    }
    if (in.cron) |v| {
        if (v.len > 0 and !cron.valid(v)) return error.BadCron;
        svc.cron = v;
    }
    if (in.backup_schedule) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "daily") and !std.mem.eql(u8, v, "weekly")) return error.BadSchedule;
        svc.backup_schedule = v;
    }
    if (in.port) |v| svc.port = v;
    if (in.domains) |v| {
        for (v) |d| if (!store_mod.validDomain(d)) return error.BadDomain;
        svc.domains = v;
    }

    if (in.health_path) |v| {
        if (v.len > 0 and v[0] != '/') return error.BadHealthPath;
        svc.health_path = v;
    }
    if (in.sleep_after_s) |v| svc.sleep_after_s = v;
    if (in.x) |v| svc.x = v;
    if (in.y) |v| svc.y = v;
}

/// Runs `pharbor _deploy` on its own: it outlives this request and the panel.
fn startDeploy(c: *Ctx, id: []const u8, trigger: []const u8) void {
    startDeployFrom(c, id, trigger, null);
}

fn startDeployFrom(c: *Ctx, id: []const u8, trigger: []const u8, from: ?u32) void {
    const id_z = c.a.dupeSentinel(u8, id, 0) catch return;
    const trig_z = c.a.dupeSentinel(u8, trigger, 0) catch return;
    const from_z = if (from) |n| std.fmt.allocPrintSentinel(c.a, "{d}", .{n}, 0) catch return else null;
    const argv = [_:null]?[*:0]const u8{ "pharbor", "_deploy", id_z.ptr, trig_z.ptr, if (from_z) |f| f.ptr else null };
    const pid = sys.fork() catch return;
    if (pid == 0) {
        _ = linux.setsid();
        if ((sys.fork() catch linux.exit_group(1)) != 0) linux.exit_group(0);
        const null_fd = sys.open("/dev/null", sys.O_RDWR, 0) catch linux.exit_group(1);
        _ = linux.dup2(null_fd, 0);
        _ = linux.dup2(null_fd, 1);
        _ = linux.dup2(null_fd, 2);
        _ = linux.execve("/proc/self/exe", &argv, c.panel.envp);
        linux.exit_group(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
}

fn services(c: *Ctx, seg: []const []const u8) !void {
    if (seg.len == 0 and method(c, "GET")) {
        const project = c.req.param("project");
        const env = c.req.param("environment");
        var out: std.ArrayList(ServiceView) = .empty;
        for (try c.store.list()) |svc| {
            if (project) |p| if (!eql(svc.project, p)) continue;
            if (env) |e| if (!eql(svc.environment, e)) continue;
            try out.append(c.a, try serviceView(c, svc));
        }
        return c.res.json(200, out.items);
    }
    if (seg.len == 0 and method(c, "POST")) {
        const in = c.req.json(ServiceInput) catch return c.res.fail(400, "invalid service");
        const name = in.name orelse return c.res.fail(400, "send name");
        const project = in.project orelse store_mod.default_project;
        const env = in.environment orelse store_mod.default_environment;
        for ([_][]const u8{ name, project, env }) |n| if (!validName(n)) return c.res.fail(400, "names use a-z, 0-9 and -");
        var svc: Service = .{ .name = name, .project = project, .environment = env };
        applyInput(&svc, in) catch |e| return c.res.fail(400, @errorName(e));
        {
            const lock = try c.store.lock();
            defer c.store.unlock(lock);
            if (c.store.exists(c.store.idOf(svc))) return c.res.fail(409, "a service with this name exists");
            try c.store.ensureEnvironment(project, env);
            try c.store.save(svc);
            if (in.env) |list| {
                const parsed = parseEntries(c.a, list) catch return c.res.fail(400, "env entries are KEY=VALUE");
                c.vars.put(project, env, name, parsed) catch return c.res.fail(400, "invalid variable name");
            }
        }
        if (in.deploy and (svc.image.len > 0 or svc.repo.len > 0)) startDeploy(c, c.store.idOf(svc), "api");
        return c.res.json(201, try serviceView(c, svc));
    }
    if (seg.len == 0) return c.res.fail(405, "method not allowed");

    const id = seg[0];
    if (!c.store.exists(id)) return c.res.fail(404, "no such service");
    const svc = try c.store.load(id);
    if (seg.len == 1) {
        if (method(c, "GET")) return c.res.json(200, try serviceView(c, svc));
        if (method(c, "PATCH")) {
            const in = c.req.json(ServiceInput) catch return c.res.fail(400, "invalid service");
            const lock = try c.store.lock();
            var current = try c.store.load(id);
            applyInput(&current, in) catch |e| {
                c.store.unlock(lock);
                return c.res.fail(400, @errorName(e));
            };
            try c.store.save(current);
            c.store.syncRoutes();
            c.store.unlock(lock);
            if (in.deploy) startDeploy(c, id, "api");
            return c.res.json(200, try serviceView(c, current));
        }
        if (method(c, "DELETE")) {
            const lock = try c.store.lock();
            defer c.store.unlock(lock);
            deploy.forget(c.store, &c.eng, c.vars, svc);
            c.store.syncRoutes();
            return c.res.json(200, .{ .ok = true });
        }
        return c.res.fail(405, "method not allowed");
    }
    const what = seg[1];
    if (eql(what, "variables")) return variables(c, svc.project, svc.environment, svc.name, seg[2..]);
    if (eql(what, "deploy") and method(c, "POST")) {
        if (svc.image.len == 0 and svc.repo.len == 0) return c.res.fail(400, "set an image or a repository first");
        startDeploy(c, id, "api");
        return c.res.json(202, .{ .ok = true });
    }
    if (eql(what, "run") and method(c, "POST")) {
        if (svc.cron.len == 0) return c.res.fail(409, "not a cron service");
        scheduler.spawn(c.panel.envp, "_cronrun", id);
        return c.res.json(202, .{ .ok = true });
    }
    if (eql(what, "cron-log") and method(c, "GET")) {
        const data = sys.readFileAlloc(c.a, scheduler.logPath(c.store, id), 1 << 26) catch "";
        return c.res.send(200, "text/plain; charset=utf-8", lastLines(data, 500));
    }
    if (eql(what, "volumes") and method(c, "GET")) {
        const View = struct { name: []const u8, mount: []const u8, size: u64 };
        var out: std.ArrayList(View) = .empty;
        for (svc.volumes) |v| try out.append(c.a, .{ .name = v.name, .mount = v.mount, .size = backup.usage(backup.volumeDir(c.store, id, v.name)) });
        return c.res.json(200, out.items);
    }
    if (eql(what, "backups")) {
        if (seg.len == 2 and method(c, "GET")) {
            var out: std.ArrayList(backup.Backup) = .empty;
            for (svc.volumes) |v| try out.appendSlice(c.a, try backup.list(c.store, id, v.name));
            return c.res.json(200, out.items);
        }
        if (seg.len == 2 and method(c, "POST")) {
            const body = c.req.json(struct { volume: ?[]const u8 = null, live: bool = false }) catch return c.res.fail(400, "invalid request");
            if (svc.volumes.len == 0) return c.res.fail(409, "this service has no volumes");
            var made: std.ArrayList(backup.Backup) = .empty;
            for (svc.volumes) |v| {
                if (body.volume) |want| if (!eql(want, v.name)) continue;
                try made.append(c.a, backup.create(c.store, &c.eng, svc, v.name, !body.live) catch |e| return c.res.fail(500, @errorName(e)));
            }
            return c.res.json(201, made.items);
        }
        if (seg.len == 5 and eql(seg[4], "restore") and method(c, "POST")) {
            backup.restore(c.store, &c.eng, svc, seg[2], seg[3]) catch |e| return c.res.fail(if (e == error.NoSuchBackup) 404 else 500, @errorName(e));
            return c.res.json(200, .{ .ok = true });
        }
        if (seg.len == 4 and method(c, "DELETE")) {
            backup.remove(c.store, id, seg[2], seg[3]) catch return c.res.fail(404, "no such backup");
            return c.res.json(200, .{ .ok = true });
        }
        return c.res.fail(404, "not found");
    }
    if ((eql(what, "rollback") or eql(what, "redeploy")) and method(c, "POST")) {
        const body = c.req.json(struct { number: ?u32 = null }) catch return c.res.fail(400, "send number");
        var number = body.number;
        if (number == null) {
            for (try c.store.listDeployments(id)) |d| {
                if (eql(d.status, "active")) {
                    number = d.number;
                    break;
                }
            }
        }
        const n = number orelse return c.res.fail(409, "nothing is deployed yet");
        _ = c.store.loadDeployment(id, n) catch return c.res.fail(404, "no such deployment");
        startDeployFrom(c, id, what, n);
        return c.res.json(202, .{ .ok = true, .from = n });
    }
    if (eql(what, "restart") and method(c, "POST")) {
        if (svc.container.len == 0) return c.res.fail(409, "not deployed");
        _ = try c.eng.output(&.{ "restart", svc.container });
        return c.res.json(200, .{ .ok = true });
    }
    if (eql(what, "deployments") and method(c, "GET")) {
        if (seg.len == 4 and eql(seg[3], "log")) {
            const n = std.fmt.parseInt(u32, seg[2], 10) catch return c.res.fail(400, "bad number");
            const data = sys.readFileAlloc(c.a, c.store.deploymentLog(id, n), 1 << 24) catch "";
            return c.res.send(200, "text/plain; charset=utf-8", data);
        }
        return c.res.json(200, try c.store.listDeployments(id));
    }
    if (eql(what, "logs") and method(c, "GET")) {
        if (svc.container.len == 0) return c.res.send(200, "text/plain; charset=utf-8", "");
        const tail = c.req.param("tail") orelse "500";
        const out = try c.eng.output(&.{ "logs", "--tail", tail, svc.container });
        return c.res.send(200, "text/plain; charset=utf-8", out.text);
    }
    if (eql(what, "terminal") and method(c, "GET")) return openTerminal(c, svc);
    if (eql(what, "metrics") and method(c, "GET")) {
        const range = std.fmt.parseInt(i64, c.req.param("range") orelse "3600", 10) catch return c.res.fail(400, "range is in seconds");
        const series = try metrics.query(c.a, c.store, id, std.math.clamp(range, 300, 7 * 86400), nowS(), 240);
        return c.res.json(200, .{ .interval = metrics.interval_s, .step = series.step, .from = series.from, .to = series.to, .points = series.points });
    }
    if (eql(what, "http-logs") and method(c, "GET")) {
        const file = try std.fmt.allocPrint(c.a, "{s}/http/{s}.log", .{ c.store.root, id });
        const data = sys.readFileAlloc(c.a, file, 1 << 26) catch "";
        const n = std.fmt.parseInt(usize, c.req.param("tail") orelse "500", 10) catch 500;
        return c.res.send(200, "application/x-ndjson", lastLines(data, n));
    }
    c.res.fail(404, "not found");
}

/// Browsers send cookies with a WebSocket handshake from any site, and
/// without a preflight: the Origin header is all that tells them apart.
fn fromThisOrigin(c: *Ctx) bool {
    const origin = c.req.header("origin") orelse return false;
    const host = c.req.header("x-forwarded-host") orelse c.req.header("host") orelse return false;
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return false;
    return eql(origin[scheme_end + 3 ..], host);
}

fn openTerminal(c: *Ctx, svc: Service) !void {
    if (c.who.token == null and !fromThisOrigin(c)) return c.res.fail(403, "the terminal only opens from this dashboard");
    const key = c.req.header("sec-websocket-key") orelse return c.res.fail(400, "this is a WebSocket");
    if (svc.container.len == 0) return c.res.fail(409, "the service is not deployed");
    const info = c.eng.inspect(svc.container) orelse return c.res.fail(409, "the service is not running");
    if (!info.running()) return c.res.fail(409, "the service is not running");
    const fd = c.res.hijack();
    ws.handshake(fd, key) catch return;
    terminal.session(c.a, fd, c.panel.pdock, c.panel.envp, svc.container);
}

const LogLine = struct { t: i64, service: []const u8, stream: []const u8, text: []const u8 };

/// The latest output of every service of an environment, merged by time,
/// keeping the lines that contain `q` (any case).
fn environmentLogs(c: *Ctx, project: []const u8, env: []const u8) !void {
    const tail = std.fmt.parseInt(u32, c.req.param("tail") orelse "300", 10) catch return c.res.fail(400, "bad tail");
    const tail_text = try std.fmt.allocPrint(c.a, "{d}", .{@min(tail, 5000)});
    const q = c.req.text("q") orelse "";
    const only = c.req.text("service");
    var out: std.ArrayList(LogLine) = .empty;
    for (try c.store.listIn(project, env)) |svc| {
        if (svc.container.len == 0) continue;
        if (only) |o| if (o.len > 0 and !eql(o, svc.name)) continue;
        const res = c.eng.output(&.{ "logs", "-t", "--tail", tail_text, svc.container }) catch continue;
        var lines = std.mem.splitScalar(u8, res.text, '\n');
        while (lines.next()) |line| {
            const l = parseLogLine(line) orelse continue;
            if (q.len > 0 and !containsIgnoreCase(l.text, q)) continue;
            try out.append(c.a, .{ .t = l.t, .service = svc.name, .stream = l.stream, .text = l.text });
        }
    }
    std.mem.sort(LogLine, out.items, {}, struct {
        fn lessThan(_: void, x: LogLine, y: LogLine) bool {
            return x.t < y.t;
        }
    }.lessThan);
    const keep = @min(out.items.len, 2000);
    c.res.json(200, out.items[out.items.len - keep ..]);
}

/// `2026-11-11T13:14:46.030Z stdout F text`, as `pdock logs -t` prints.
fn parseLogLine(line: []const u8) ?struct { t: i64, stream: []const u8, text: []const u8 } {
    var it = std.mem.splitScalar(u8, line, ' ');
    const stamp = it.next() orelse return null;
    const stream = it.next() orelse return null;
    _ = it.next() orelse return null;
    return .{ .t = parseStamp(stamp) orelse return null, .stream = stream, .text = it.rest() };
}

/// Milliseconds since 1970 from `YYYY-MM-DDTHH:MM:SS[.mmm]Z`.
fn parseStamp(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[10] != 'T' or s[s.len - 1] != 'Z') return null;
    const num = struct {
        fn f(x: []const u8) ?i64 {
            return std.fmt.parseInt(i64, x, 10) catch null;
        }
    }.f;
    const y = num(s[0..4]) orelse return null;
    const mo = num(s[5..7]) orelse return null;
    const d = num(s[8..10]) orelse return null;
    const h = num(s[11..13]) orelse return null;
    const mi = num(s[14..16]) orelse return null;
    const sec = num(s[17..19]) orelse return null;
    var ms: i64 = 0;
    if (s.len >= 24 and s[19] == '.') ms = num(s[20..23]) orelse 0;
    // Days from civil, after Howard Hinnant.
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 24 + h) * 60 + mi) * 60_000 + sec * 1000 + ms;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "log lines" {
    const l = parseLogLine("2026-11-11T13:14:46.030Z stdout F Ready to accept connections").?;
    try std.testing.expectEqual(@as(i64, 1794402886030), l.t);
    try std.testing.expectEqualStrings("stdout", l.stream);
    try std.testing.expectEqualStrings("Ready to accept connections", l.text);
    try std.testing.expectEqual(@as(?i64, 0), parseStamp("1970-01-01T00:00:00Z"));
    try std.testing.expect(parseLogLine("garbage") == null);
    try std.testing.expect(containsIgnoreCase("Hello World", "o w"));
    try std.testing.expect(!containsIgnoreCase("Hello", "hello!"));
}

const Edge = struct { from: []const u8, to: []const u8 };

/// Which service refers to which, from ${{ name.KEY }} in their variables:
/// the dashed arrows of the canvas.
fn edges(c: *Ctx, project: []const u8, env: []const u8) ![]Edge {
    var out: std.ArrayList(Edge) = .empty;
    const list = try c.store.listIn(project, env);
    for (list) |svc| {
        for (try c.vars.get(project, env, svc.name)) |v| {
            var rest = v.value;
            while (std.mem.indexOf(u8, rest, "${{")) |start| {
                const end = std.mem.indexOfPos(u8, rest, start, "}}") orelse break;
                const ref = std.mem.trim(u8, rest[start + 3 .. end], " ");
                rest = rest[end + 2 ..];
                const dot = std.mem.indexOfScalar(u8, ref, '.') orelse continue;
                const target = ref[0..dot];
                if (eql(target, "shared") or eql(target, svc.name)) continue;
                var exists = false;
                for (list) |other| exists = exists or eql(other.name, target);
                if (!exists) continue;
                var dup = false;
                for (out.items) |e| dup = dup or (eql(e.from, svc.name) and eql(e.to, target));
                if (!dup) try out.append(c.a, .{ .from = svc.name, .to = target });
            }
        }
    }
    return out.items;
}

fn parseEntries(a: Allocator, list: []const []const u8) ![]vars_mod.Var {
    const out = try a.alloc(vars_mod.Var, list.len);
    for (list, 0..) |e, i| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse return error.BadEnv;
        out[i] = .{ .name = e[0..eq], .value = e[eq + 1 ..] };
    }
    return out;
}

/// The variables of a service, or of an environment with `service` null.
fn variables(c: *Ctx, project: []const u8, env: []const u8, service: ?[]const u8, seg: []const []const u8) !void {
    if (seg.len == 0 and method(c, "GET")) {
        if (c.req.param("resolved") != null) {
            const name = service orelse return c.res.fail(400, "only a service's variables resolve");
            var warnings: std.ArrayList([]const u8) = .empty;
            const svc = try c.store.load(c.store.idFrom(project, env, name));
            const list = c.vars.resolve(svc, &warnings) catch |e| return c.res.fail(400, @errorName(e));
            return c.res.json(200, .{ .variables = list, .warnings = warnings.items });
        }
        return c.res.json(200, try c.vars.get(project, env, service));
    }
    const lock = try c.store.lock();
    defer c.store.unlock(lock);
    const current = try c.vars.get(project, env, service);
    var next: []vars_mod.Var = undefined;
    if (seg.len == 0 and method(c, "PUT")) {
        const body = c.req.json(struct { variables: []const vars_mod.Var }) catch return c.res.fail(400, "send variables");
        next = try vars_mod.merge(c.a, &.{}, body.variables, &.{});
    } else if (seg.len == 0 and method(c, "PATCH")) {
        const body = c.req.json(struct { set: []const vars_mod.Var = &.{}, unset: []const []const u8 = &.{} }) catch return c.res.fail(400, "send set and unset");
        next = try vars_mod.merge(c.a, current, body.set, body.unset);
    } else if (seg.len == 1 and eql(seg[0], "raw") and method(c, "POST")) {
        // A pasted .env file, as text inside JSON.
        const body = c.req.json(struct { text: []const u8, replace: bool = false }) catch return c.res.fail(400, "send text");
        const parsed = vars_mod.parseDotenv(c.a, body.text) catch |e| return c.res.fail(400, @errorName(e));
        next = try vars_mod.merge(c.a, if (body.replace) &.{} else current, parsed, &.{});
    } else {
        return c.res.fail(405, "method not allowed");
    }
    c.vars.put(project, env, service, next) catch |e| return c.res.fail(400, if (e == error.BadKey) "names use A-Z, 0-9 and _, and do not start with a digit" else @errorName(e));
    c.res.json(200, next);
}

fn lastLines(text: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    var i = text.len;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] == '\n') {
            count += 1;
            if (count > n) return text[i..];
        }
    }
    return text;
}

fn webhookSecret(c: *Ctx) ![]const u8 {
    const lock = try c.store.lock();
    defer c.store.unlock(lock);
    var s = c.store.settings();
    if (s.webhook_secret.len == 0) {
        var raw: [24]u8 = undefined;
        crypto.random(&raw);
        s.webhook_secret = try crypto.seal(c.a, c.panel.key, try crypto.hex(c.a, &raw));
        try c.store.saveSettings(s);
    }
    return crypto.open(c.a, c.panel.key, s.webhook_secret);
}

/// Runs `pharbor ARGS...` and returns what it printed; the tunnel commands
/// already know how to wait for cloudflared.
fn runSelf(c: *Ctx, args: []const []const u8) !struct { code: u8, text: []const u8 } {
    const argv = try c.a.allocSentinel(?[*:0]const u8, args.len + 1, null);
    argv[0] = "pharbor";
    for (args, 0..) |s, i| argv[i + 1] = (try c.a.dupeSentinel(u8, s, 0)).ptr;
    var pipe: [2]i32 = undefined;
    _ = try sys.ck(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
    const pid = try sys.fork();
    if (pid == 0) {
        _ = linux.dup2(pipe[1], 1);
        _ = linux.dup2(pipe[1], 2);
        _ = linux.execve("/proc/self/exe", argv.ptr, c.panel.envp);
        linux.exit_group(127);
    }
    sys.close(pipe[1]);
    defer sys.close(pipe[0]);
    var text: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(pipe[0], &buf) catch break;
        if (n == 0) break;
        try text.appendSlice(c.a, buf[0..n]);
    }
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
    const st: u32 = @bitCast(status);
    return .{ .code = if (linux.W.IFEXITED(st)) linux.W.EXITSTATUS(st) else 1, .text = text.items };
}

fn tunnelApi(c: *Ctx, seg: []const []const u8) !void {
    if (seg.len == 0 and method(c, "GET")) {
        const out = try runSelf(c, &.{ "tunnel", "status" });
        var lines = std.mem.tokenizeScalar(u8, out.text, '\n');
        const status = lines.next() orelse "";
        var url: []const u8 = "";
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "https://")) url = l;
        }
        return c.res.json(200, .{
            .running = eql(status, "running"),
            .status = if (eql(status, "No tunnel")) "" else status,
            .url = url,
            .default_service = c.store.settings().default_service,
        });
    }
    if (seg.len == 1 and eql(seg[0], "quick") and method(c, "POST")) {
        const body = c.req.json(struct { service: []const u8 }) catch return c.res.fail(400, "send service");
        if (!c.store.exists(body.service)) return c.res.fail(404, "no such service");
        const svc = try c.store.load(body.service);
        const out = try runSelf(c, &.{ "tunnel", "quick", svc.name, "--project", svc.project, "--env", svc.environment });
        if (out.code != 0) return c.res.fail(502, out.text);
        const i = std.mem.indexOf(u8, out.text, "https://") orelse return c.res.fail(502, out.text);
        const end = std.mem.indexOfScalarPos(u8, out.text, i, ' ') orelse out.text.len;
        return c.res.json(201, .{ .url = out.text[i..end] });
    }
    if (seg.len == 1 and eql(seg[0], "named") and method(c, "POST")) {
        const body = c.req.json(struct { token: []const u8 }) catch return c.res.fail(400, "send token");
        const out = try runSelf(c, &.{ "tunnel", "start", body.token });
        if (out.code != 0) return c.res.fail(502, out.text);
        return c.res.json(201, .{ .output = out.text });
    }
    if (seg.len == 0 and method(c, "DELETE")) {
        _ = try runSelf(c, &.{ "tunnel", "stop" });
        return c.res.json(200, .{ .ok = true });
    }
    c.res.fail(404, "not found");
}

fn templatesApi(c: *Ctx, seg: []const []const u8) !void {
    if (seg.len == 0 and method(c, "GET")) {
        const View = struct { id: []const u8, name: []const u8, category: []const u8, description: []const u8, image: []const u8, port: u16, connect: []const u8 };
        var out: std.ArrayList(View) = .empty;
        for (templates.all) |tpl| try out.append(c.a, .{
            .id = tpl.id,
            .name = tpl.name,
            .category = tpl.category,
            .description = tpl.description,
            .image = tpl.image,
            .port = tpl.port,
            .connect = tpl.connect,
        });
        return c.res.json(200, out.items);
    }
    if (seg.len != 1 or !method(c, "POST")) return c.res.fail(404, "not found");
    const tpl = templates.find(seg[0]) orelse return c.res.fail(404, "no such template");
    const body = c.req.json(struct {
        project: []const u8 = store_mod.default_project,
        environment: []const u8 = store_mod.default_environment,
        name: ?[]const u8 = null,
        x: i32 = 0,
        y: i32 = 0,
    }) catch return c.res.fail(400, "invalid request");
    const base = body.name orelse tpl.id;
    for ([_][]const u8{ base, body.project, body.environment }) |n| if (!validName(n)) return c.res.fail(400, "names use a-z, 0-9 and -");

    var svc: Service = .{ .name = base, .project = body.project, .environment = body.environment };
    {
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        // postgres, postgres-2, postgres-3...
        var n: u32 = 2;
        while (c.store.exists(c.store.idOf(svc))) : (n += 1) {
            if (body.name != null) return c.res.fail(409, "a service with this name exists");
            svc.name = try std.fmt.allocPrint(c.a, "{s}-{d}", .{ base, n });
        }
        svc.image = tpl.image;
        svc.port = tpl.port;
        svc.start_command = tpl.start_command;
        const volume = [_]store_mod.Volume{.{ .name = try std.fmt.allocPrint(c.a, "{s}-data", .{svc.name}), .mount = tpl.mount }};
        svc.volumes = try c.a.dupe(store_mod.Volume, &volume);
        svc.x = body.x;
        svc.y = body.y;
        try c.store.ensureEnvironment(svc.project, svc.environment);
        try c.store.save(svc);
        var secret: [24]u8 = undefined;
        templates.password(&secret);
        try c.vars.put(svc.project, svc.environment, svc.name, try templates.variables(c.a, tpl, &secret));
    }
    startDeploy(c, c.store.idOf(svc), "api");
    c.res.json(201, try serviceView(c, svc));
}

const ChannelView = struct {
    id: []const u8,
    name: []const u8,
    kind: alerts.Kind,
    events: []const []const u8,
    projects: []const []const u8,
    enabled: bool,
    email_from: []const u8,
    email_to: []const []const u8,
    signed: bool,
    /// Enough of the address to recognise it, not to use it.
    target: []const u8,
};

fn channelView(c: *Ctx, ch: alerts.Channel) ChannelView {
    const plain = crypto.open(c.a, c.panel.key, ch.target) catch "";
    var hint: []const u8 = "";
    if (ch.kind == .email) {
        hint = if (plain.len > 8) std.fmt.allocPrint(c.a, "{s}...{s}", .{ plain[0..3], plain[plain.len - 4 ..] }) catch "" else "";
    } else if (std.Uri.parse(plain)) |uri| {
        const host = if (uri.host) |h| h.percent_encoded else "";
        hint = std.fmt.allocPrint(c.a, "{s}/...{s}", .{ host, plain[plain.len -| 4..] }) catch "";
    } else |_| {}
    return .{
        .id = ch.id,
        .name = ch.name,
        .kind = ch.kind,
        .events = ch.events,
        .projects = ch.projects,
        .enabled = ch.enabled,
        .email_from = ch.email_from,
        .email_to = ch.email_to,
        .signed = ch.signing.len > 0,
        .target = hint,
    };
}

fn alertsApi(c: *Ctx, seg: []const []const u8) !void {
    if (seg.len == 0 and method(c, "GET")) {
        const cfg = alerts.load(c.store);
        var views: std.ArrayList(ChannelView) = .empty;
        for (cfg.channels) |ch| try views.append(c.a, channelView(c, ch));
        return c.res.json(200, .{ .channels = views.items, .thresholds = cfg.thresholds, .events = alerts.event_kinds, .defaults = alerts.default_events });
    }
    if (seg.len == 1 and eql(seg[0], "log") and method(c, "GET")) {
        const data = sys.readFileAlloc(c.a, alerts.logPath(c.store), 1 << 20) catch "";
        var out: std.ArrayList(alerts.Delivery) = .empty;
        var lines = std.mem.splitBackwardsScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (out.items.len == 50) break;
            const d = std.json.parseFromSliceLeaky(alerts.Delivery, c.a, line, .{ .ignore_unknown_fields = true }) catch continue;
            try out.append(c.a, d);
        }
        return c.res.json(200, out.items);
    }
    if (seg.len == 1 and eql(seg[0], "thresholds") and method(c, "PUT")) {
        const body = c.req.json(alerts.Thresholds) catch return c.res.fail(400, "send cpu_percent, memory_mb and disk_mb");
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        var cfg = alerts.load(c.store);
        cfg.thresholds = body;
        try alerts.save(c.store, cfg);
        return c.res.json(200, cfg.thresholds);
    }
    if (seg.len == 1 and eql(seg[0], "channels") and method(c, "POST")) {
        const In = struct {
            name: []const u8,
            kind: alerts.Kind,
            /// The webhook URL, or the Resend API key for email.
            target: []const u8,
            signing: []const u8 = "",
            email_from: []const u8 = "",
            email_to: []const []const u8 = &.{},
            events: ?[]const []const u8 = null,
            projects: []const []const u8 = &.{},
        };
        const body = c.req.json(In) catch return c.res.fail(400, "send name, kind and target");
        const target = std.mem.trim(u8, body.target, " ");
        if (std.mem.trim(u8, body.name, " ").len == 0) return c.res.fail(400, "give the channel a name");
        if (!alerts.validTarget(body.kind, target)) return c.res.fail(400, switch (body.kind) {
            .discord => "use the webhook URL from the Discord channel's Integrations settings",
            .slack => "use an incoming webhook URL from hooks.slack.com",
            .webhook => "use an http:// or https:// URL",
            .email => "paste the Resend API key",
        });
        if (body.kind == .email) {
            if (body.email_from.len == 0 or body.email_to.len == 0) return c.res.fail(400, "email needs a sender and at least one recipient");
            for (body.email_to) |to| if (std.mem.indexOfScalar(u8, to, '@') == null) return c.res.fail(400, "a recipient is not an email address");
        }
        const events = body.events orelse &alerts.default_events;
        for (events) |e| if (!alerts.knownEvent(e)) return c.res.fail(400, "unknown event");
        var raw: [8]u8 = undefined;
        crypto.random(&raw);
        const ch: alerts.Channel = .{
            .id = try crypto.hex(c.a, &raw),
            .name = std.mem.trim(u8, body.name, " "),
            .kind = body.kind,
            .target = try crypto.seal(c.a, c.panel.key, target),
            .signing = if (body.signing.len > 0) try crypto.seal(c.a, c.panel.key, body.signing) else "",
            .email_from = body.email_from,
            .email_to = body.email_to,
            .events = events,
            .projects = body.projects,
        };
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        var cfg = alerts.load(c.store);
        var list: std.ArrayList(alerts.Channel) = .empty;
        try list.appendSlice(c.a, cfg.channels);
        try list.append(c.a, ch);
        cfg.channels = list.items;
        try alerts.save(c.store, cfg);
        return c.res.json(201, channelView(c, ch));
    }
    if (seg.len >= 2 and eql(seg[0], "channels")) {
        const id = seg[1];
        var cfg = alerts.load(c.store);
        var index: ?usize = null;
        for (cfg.channels, 0..) |ch, i| {
            if (eql(ch.id, id)) index = i;
        }
        const i = index orelse return c.res.fail(404, "no such channel");
        if (seg.len == 3 and eql(seg[2], "test") and method(c, "POST")) {
            const ch = cfg.channels[i];
            const ev: alerts.Event = .{
                .kind = "test",
                .title = "Test alert from PocketHarbor",
                .detail = "If you can read this, the channel works.",
                .severity = .info,
                .at = nowS(),
            };
            const failure = alerts.deliver(c.a, c.panel.io, c.panel.key, ch, ev);
            return c.res.json(200, .{ .ok = failure == null, .@"error" = failure orelse "" });
        }
        if (seg.len != 2) return c.res.fail(404, "not found");
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        cfg = alerts.load(c.store);
        var list: std.ArrayList(alerts.Channel) = .empty;
        try list.appendSlice(c.a, cfg.channels);
        if (i >= list.items.len or !eql(list.items[i].id, id)) return c.res.fail(409, "the channels changed; try again");
        if (method(c, "DELETE")) {
            _ = list.orderedRemove(i);
            cfg.channels = list.items;
            try alerts.save(c.store, cfg);
            return c.res.json(200, .{ .ok = true });
        }
        if (method(c, "PATCH")) {
            const In = struct { name: ?[]const u8 = null, enabled: ?bool = null, events: ?[]const []const u8 = null, projects: ?[]const []const u8 = null };
            const body = c.req.json(In) catch return c.res.fail(400, "invalid channel");
            var ch = &list.items[i];
            if (body.name) |n| ch.name = n;
            if (body.enabled) |e| ch.enabled = e;
            if (body.events) |evs| {
                for (evs) |e| if (!alerts.knownEvent(e)) return c.res.fail(400, "unknown event");
                ch.events = evs;
            }
            if (body.projects) |p| ch.projects = p;
            cfg.channels = list.items;
            try alerts.save(c.store, cfg);
            return c.res.json(200, channelView(c, ch.*));
        }
        return c.res.fail(405, "method not allowed");
    }
    c.res.fail(404, "not found");
}

/// Credentials for private image registries, kept by the engine.
fn registries(c: *Ctx, seg: []const []const u8) !void {
    if (seg.len == 0 and method(c, "GET")) return c.res.json(200, c.eng.registries());
    if (seg.len == 0 and method(c, "POST")) {
        const body = c.req.json(struct { host: []const u8, username: []const u8, password: []const u8 }) catch return c.res.fail(400, "send host, username and password");
        if (body.host.len == 0 or std.mem.indexOfAny(u8, body.host, " /") != null) return c.res.fail(400, "the host is a name like ghcr.io");
        const out = try c.eng.outputWithInput(&.{ "login", body.host, "-u", body.username, "--password-stdin" }, body.password);
        if (out.code != 0) return c.res.fail(400, std.mem.trim(u8, out.text, "\n"));
        return c.res.json(201, .{ .host = body.host });
    }
    if (seg.len == 1 and method(c, "DELETE")) {
        const out = try c.eng.output(&.{ "logout", seg[0] });
        if (out.code != 0) return c.res.fail(404, "not logged in to that registry");
        return c.res.json(200, .{ .ok = true });
    }
    c.res.fail(404, "not found");
}

fn githubSettings(c: *Ctx, seg: []const []const u8) !void {
    if (seg.len == 0 and method(c, "GET")) {
        return c.res.json(200, .{
            .has_token = c.store.settings().github_token.len > 0,
            .webhook_path = "/__pharbor/webhooks/github",
            .webhook_secret = try webhookSecret(c),
        });
    }
    if (seg.len == 0 and method(c, "PUT")) {
        const body = c.req.json(struct { token: []const u8 }) catch return c.res.fail(400, "send token");
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        var s = c.store.settings();
        s.github_token = if (body.token.len == 0) "" else try crypto.seal(c.a, c.panel.key, body.token);
        try c.store.saveSettings(s);
        return c.res.json(200, .{ .has_token = body.token.len > 0 });
    }
    c.res.fail(404, "not found");
}

/// A push on GitHub deploys every service that follows that branch.
fn webhook(c: *Ctx) !void {
    if (!method(c, "POST")) return c.res.fail(405, "method not allowed");
    const signature = c.req.header("x-hub-signature-256") orelse return c.res.fail(401, "unsigned");
    if (!github.verifySignature(try webhookSecret(c), c.req.body, signature)) return c.res.fail(401, "bad signature");
    const event = c.req.header("x-github-event") orelse "";
    if (eql(event, "ping")) return c.res.json(200, .{ .ok = true });
    if (!eql(event, "push")) return c.res.json(202, .{ .ignored = event });
    const Push = struct { ref: []const u8 = "", repository: struct { full_name: []const u8 = "" } = .{}, deleted: bool = false };
    const push = c.req.json(Push) catch return c.res.fail(400, "unreadable payload");
    if (push.deleted or !std.mem.startsWith(u8, push.ref, "refs/heads/")) return c.res.json(202, .{ .deployed = 0 });
    const branch = push.ref["refs/heads/".len..];
    var started: usize = 0;
    for (try c.store.list()) |svc| {
        if (!svc.auto_deploy or !std.ascii.eqlIgnoreCase(svc.repo, push.repository.full_name) or !eql(svc.branch, branch)) continue;
        startDeploy(c, c.store.idOf(svc), "webhook");
        started += 1;
    }
    c.res.json(202, .{ .deployed = started });
}

fn settings(c: *Ctx) !void {
    if (method(c, "GET")) {
        var s = c.store.settings();
        // Never sent back; the GitHub endpoint says whether they are set.
        s.github_token = if (s.github_token.len > 0) "set" else "";
        s.webhook_secret = "";
        return c.res.json(200, s);
    }
    if (method(c, "PATCH")) {
        const in = c.req.json(struct { base_domain: ?[]const u8 = null, panel_domain: ?[]const u8 = null }) catch return c.res.fail(400, "invalid settings");
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        var s = c.store.settings();
        if (in.base_domain) |d| {
            if (d.len > 0 and !store_mod.validDomain(d)) return c.res.fail(400, "invalid domain");
            s.base_domain = d;
        }
        if (in.panel_domain) |d| {
            if (d.len > 0 and !store_mod.validDomain(d)) return c.res.fail(400, "invalid domain");
            s.panel_domain = d;
        }
        try c.store.saveSettings(s);
        c.store.syncRoutes();
        return c.res.json(200, s);
    }
    c.res.fail(405, "method not allowed");
}
