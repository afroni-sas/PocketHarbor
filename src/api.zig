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
    };
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

const ServiceView = struct {
    id: []const u8,
    project: []const u8,
    environment: []const u8,
    name: []const u8,
    image: []const u8,
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
    const status: []const u8 = if (svc.asleep) "asleep" else if (info) |i| i.status else if (svc.deployment > 0) "failed" else "new";
    return .{
        .id = c.store.idOf(svc),
        .project = svc.project,
        .environment = svc.environment,
        .name = svc.name,
        .image = svc.image,
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
                if (svc.asleep) {
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
            if (!eql(svc.project, name)) continue;
            c.store.remove(c.store.idOf(svc));
            if (svc.container.len > 0) c.eng.remove(svc.container);
        }
        c.store.removeProject(name);
        c.store.syncRoutes();
        return c.res.json(200, .{ .ok = true });
    }
    if (seg.len == 2 and eql(seg[1], "environments") and method(c, "POST")) {
        const body = c.req.json(struct { name: []const u8, from: []const u8 = store_mod.default_environment }) catch return c.res.fail(400, "send name");
        if (!validName(body.name)) return c.res.fail(400, "use a-z, 0-9 and -");
        const copied = try deploy.duplicateEnvironment(c.store, name, body.from, body.name);
        return c.res.json(201, .{ .name = body.name, .copied = copied });
    }
    if (seg.len == 3 and eql(seg[1], "environments") and method(c, "DELETE")) {
        const env = seg[2];
        if (eql(env, store_mod.default_environment)) return c.res.fail(409, "production cannot be removed");
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        for (try c.store.listIn(name, env)) |svc| {
            c.store.remove(c.store.idOf(svc));
            if (svc.container.len > 0) c.eng.remove(svc.container);
        }
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
    if (in.image) |v| svc.image = v;
    if (in.port) |v| svc.port = v;
    if (in.domains) |v| {
        for (v) |d| if (!store_mod.validDomain(d)) return error.BadDomain;
        svc.domains = v;
    }
    if (in.env) |v| {
        for (v) |e| if (std.mem.indexOfScalar(u8, e, '=') == null) return error.BadEnv;
        svc.env = v;
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
    const id_z = c.a.dupeSentinel(u8, id, 0) catch return;
    const trig_z = c.a.dupeSentinel(u8, trigger, 0) catch return;
    const argv = [_:null]?[*:0]const u8{ "pharbor", "_deploy", id_z.ptr, trig_z.ptr };
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
        }
        if (in.deploy and svc.image.len > 0) startDeploy(c, c.store.idOf(svc), "api");
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
            c.store.remove(id);
            c.store.syncRoutes();
            if (svc.container.len > 0) c.eng.remove(svc.container);
            return c.res.json(200, .{ .ok = true });
        }
        return c.res.fail(405, "method not allowed");
    }
    const what = seg[1];
    if (eql(what, "deploy") and method(c, "POST")) {
        if (svc.image.len == 0) return c.res.fail(400, "set an image first");
        startDeploy(c, id, "api");
        return c.res.json(202, .{ .ok = true });
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
    if (eql(what, "http-logs") and method(c, "GET")) {
        const file = try std.fmt.allocPrint(c.a, "{s}/http/{s}.log", .{ c.store.root, id });
        const data = sys.readFileAlloc(c.a, file, 1 << 26) catch "";
        const n = std.fmt.parseInt(usize, c.req.param("tail") orelse "500", 10) catch 500;
        return c.res.send(200, "application/x-ndjson", lastLines(data, n));
    }
    c.res.fail(404, "not found");
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

fn settings(c: *Ctx) !void {
    if (method(c, "GET")) return c.res.json(200, c.store.settings());
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
