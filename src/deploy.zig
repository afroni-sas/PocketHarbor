//! Replaces a service's container without dropping a request: the new one
//! must prove it is healthy before traffic moves, and the old one keeps
//! serving until it has. Every attempt is recorded with its own log.

const std = @import("std");
const sys = @import("sys.zig");
const net = @import("net.zig");
const engine = @import("engine.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Service = store_mod.Service;
const Deployment = store_mod.Deployment;
const Engine = engine.Engine;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    project: []const u8 = store_mod.default_project,
    environment: []const u8 = store_mod.default_environment,
    image: ?[]const u8 = null,
    port: ?u16 = null,
    domains: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    health_path: ?[]const u8 = null,
    sleep_after_s: ?u32 = null,
};

/// In-flight requests finish on the old container during this time.
const drain_ms = 3000;
const default_port: u16 = 8080;
const default_timeout_s = 180;

fn setEnv(a: Allocator, env: *std.ArrayList([]const u8), entry: []const u8) !void {
    const key_end = (std.mem.indexOfScalar(u8, entry, '=') orelse return error.BadEnv) + 1;
    for (env.items) |*e| {
        if (std.mem.startsWith(u8, e.*, entry[0..key_end])) {
            e.* = entry;
            return;
        }
    }
    try env.append(a, entry);
}

fn hasEnv(env: []const []const u8, key: []const u8) bool {
    for (env) |e| {
        if (e.len > key.len and e[key.len] == '=' and std.mem.startsWith(u8, e, key)) return true;
    }
    return false;
}

fn nowS() i64 {
    return @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s));
}

/// Writes to the deployment's log, and to the terminal for a CLI deploy.
const Log = struct {
    fd: i32,
    echo: bool,

    fn open(store: Store, id: []const u8, number: u32, echo: bool) !Log {
        try sys.mkdirP(store.deploymentDir(id), 0o700);
        var p = try sys.Path.of(store.deploymentLog(id, number));
        const fd = try sys.open(p.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND | sys.O_CLOEXEC, 0o600);
        return .{ .fd = fd, .echo = echo };
    }

    fn say(self: Log, comptime f: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, f ++ "\n", args) catch return;
        sys.writeAll(self.fd, line) catch {};
        if (self.echo) sys.writeAll(1, line) catch {};
    }

    fn raw(self: Log, text: []const u8) void {
        sys.writeAll(self.fd, text) catch {};
    }
};

/// Waits for the container to listen. Without a declared port it takes the
/// one the app was told through $PORT, or else the first it opened.
fn waitForPort(eng: *Engine, container: []const u8, want: u16, deadline: i128) !struct { container: u16, host: u16 } {
    while (sys.monoNs() < deadline) {
        const info = eng.inspect(container) orelse return error.ContainerGone;
        // Its restart policy would hide a crash until the deadline.
        if (!info.alive() or info.restarts > 0) return error.ContainerExited;
        if (want != 0) {
            if (info.hostPort(want)) |h| return .{ .container = want, .host = h };
        } else if (info.hostPort(default_port)) |h| {
            return .{ .container = default_port, .host = h };
        } else if (info.ports.len > 0) {
            return .{ .container = info.ports[0].container, .host = info.ports[0].host };
        }
        sys.sleepMs(250);
    }
    return error.NoPortOpened;
}

fn healthy(port: u16, path: []const u8) bool {
    if (path.len == 0) return net.tcpProbe(port, 1000);
    const code = net.httpStatus(port, path, 2000) orelse return false;
    return code >= 200 and code < 400;
}

fn waitHealthy(eng: *Engine, container: []const u8, port: u16, path: []const u8, deadline: i128) !void {
    while (sys.monoNs() < deadline) {
        if (healthy(port, path)) return;
        const info = eng.inspect(container) orelse return error.ContainerGone;
        if (!info.alive() or info.restarts > 0) return error.ContainerExited;
        sys.sleepMs(300);
    }
    return error.HealthCheckTimedOut;
}

fn explain(e: anyerror) []const u8 {
    return switch (e) {
        error.ContainerExited => "the container exited",
        error.ContainerGone => "the container disappeared",
        error.NoPortOpened => "the app never opened a port",
        error.HealthCheckTimedOut => "the health check never passed",
        error.StartFailed => "the container could not be started",
        else => @errorName(e),
    };
}

/// Merges what the CLI was given into the service's saved definition.
pub fn configure(store: Store, name: []const u8, opts: Options) !Service {
    const a = store.a;
    const id = store.idFrom(opts.project, opts.environment, name);
    var svc: Service = if (store.exists(id))
        try store.load(id)
    else
        .{ .name = name, .project = opts.project, .environment = opts.environment };
    if (opts.image) |i| svc.image = i;
    if (opts.port) |p| svc.port = p;
    if (opts.health_path) |p| svc.health_path = p;
    if (opts.sleep_after_s) |s| svc.sleep_after_s = s;

    var env: std.ArrayList([]const u8) = .empty;
    try env.appendSlice(a, svc.env);
    for (opts.env) |e| try setEnv(a, &env, e);
    svc.env = env.items;

    var domains: std.ArrayList([]const u8) = .empty;
    try domains.appendSlice(a, svc.domains);
    outer: for (opts.domains) |d| {
        for (domains.items) |have| {
            if (std.mem.eql(u8, have, d)) continue :outer;
        }
        try domains.append(a, d);
    }
    svc.domains = domains.items;

    const lock = try store.lock();
    defer store.unlock(lock);
    try store.ensureEnvironment(svc.project, svc.environment);
    try store.save(svc);
    return svc;
}

/// One deployment of a service at a time: each waits for the one before it.
fn lockService(store: Store, id: []const u8) !i32 {
    try sys.mkdirP(store.deploymentDir(id), 0o700);
    const file = try std.fmt.allocPrint(store.a, "{s}/lock", .{store.deploymentDir(id)});
    var p = try sys.Path.of(file);
    const fd = try sys.open(p.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_CLOEXEC, 0o600);
    const LOCK_EX = 2;
    _ = try sys.ck(sys.linux.flock(fd, LOCK_EX));
    return fd;
}

pub const RunOptions = struct {
    trigger: []const u8 = "cli",
    echo: bool = true,
    timeout_s: u32 = default_timeout_s,
};

/// Ships the service's saved definition.
pub fn run(store: Store, eng: *Engine, id: []const u8, opts: RunOptions) !void {
    const a = store.a;
    const service_lock = try lockService(store, id);
    defer sys.close(service_lock);

    var svc = try store.load(id);
    if (svc.image.len == 0) {
        sys.eprint("error: {s} has no image yet; pass --image\n", .{svc.name});
        return error.NoImage;
    }

    const number = blk: {
        const lock = try store.lock();
        defer store.unlock(lock);
        var current = try store.load(id);
        current.deployment += 1;
        try store.save(current);
        break :blk current.deployment;
    };

    const container = try std.fmt.allocPrint(a, "{s}-{s}-{s}-{d}", .{ svc.project, svc.environment, svc.name, number });
    var record: Deployment = .{
        .number = number,
        .image = svc.image,
        .trigger = opts.trigger,
        .container = container,
        .created_at = nowS(),
    };
    try store.saveDeployment(id, record);
    const log = try Log.open(store, id, number, opts.echo);
    defer sys.close(log.fd);
    log.say("Deployment {d} of {s}: {s}", .{ number, svc.name, svc.image });

    ship(store, eng, id, &svc, &record, log, opts) catch |e| {
        log.say("Deployment failed: {s}", .{explain(e)});
        record.status = "failed";
        record.reason = explain(e);
        record.finished_at = nowS();
        store.saveDeployment(id, record) catch {};
        if (!opts.echo) return;
        return error.DeployFailed;
    };
}

fn ship(store: Store, eng: *Engine, id: []const u8, svc: *Service, record: *Deployment, log: Log, opts: RunOptions) !void {
    const a = store.a;
    const container = record.container;
    eng.remove(container);

    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "run", "-d", "--name", container, "--restart", "always" });
    if (!hasEnv(svc.env, "PORT")) {
        try args.appendSlice(a, &.{ "-e", try std.fmt.allocPrint(a, "PORT={d}", .{if (svc.port != 0) svc.port else default_port}) });
    }
    for (svc.env) |e| try args.appendSlice(a, &.{ "-e", e });
    try args.append(a, svc.image);

    log.say("Starting the container", .{});
    const started = try eng.output(args.items);
    if (started.code != 0) {
        log.raw(started.text);
        return error.StartFailed;
    }

    const deadline = sys.monoNs() + @as(i128, opts.timeout_s) * std.time.ns_per_s;
    errdefer {
        const output = eng.logs(container);
        const tail = lastLines(output, 20);
        if (tail.len > 0) {
            log.say("--- last output of {s}", .{container});
            log.raw(tail);
            if (opts.echo) sys.eprint("{s}", .{tail});
        }
        eng.remove(container);
    }
    const ports = try waitForPort(eng, container, svc.port, deadline);
    log.say("Listening on port {d}, checking health", .{ports.container});
    try waitHealthy(eng, container, ports.host, svc.health_path, deadline);

    var old: []const u8 = "";
    {
        const lock = try store.lock();
        defer store.unlock(lock);
        var current = try store.load(id);
        old = current.container;
        current.container = container;
        current.port = ports.container;
        current.host_port = ports.host;
        current.asleep = false;
        current.deployed_at = nowS();
        try store.save(current);
        store.syncRoutes();
    }
    log.say("Traffic moved to {s}", .{container});

    record.status = "active";
    record.finished_at = nowS();
    try store.saveDeployment(id, record.*);
    retirePrevious(store, id, record.number);

    if (old.len > 0 and !std.mem.eql(u8, old, container)) {
        sys.sleepMs(drain_ms);
        eng.stop(old, 10);
        eng.remove(old);
    }
    log.say("Deployed {s}", .{svc.name});
}

fn retirePrevious(store: Store, id: []const u8, number: u32) void {
    const all = store.listDeployments(id) catch return;
    for (all) |d| {
        if (d.number == number or !std.mem.eql(u8, d.status, "active")) continue;
        var old = d;
        old.status = "removed";
        store.saveDeployment(id, old) catch {};
    }
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

/// Starts a sleeping or stopped service and points its route at it. Always
/// refreshes the routes: that is what releases the parked requests.
pub fn wake(store: Store, eng: *Engine, id: []const u8) void {
    defer store.syncRoutes();
    const svc = store.load(id) catch return;
    if (svc.container.len == 0) return;
    const info = eng.inspect(svc.container) orelse return;
    if (!info.alive() and !eng.start(svc.container)) return;
    const deadline = sys.monoNs() + 90 * std.time.ns_per_s;
    const ports = waitForPort(eng, svc.container, svc.port, deadline) catch return;
    waitHealthy(eng, svc.container, ports.host, svc.health_path, deadline) catch return;

    const lock = store.lock() catch return;
    defer store.unlock(lock);
    var current = store.load(id) catch return;
    if (!std.mem.eql(u8, current.container, svc.container)) return;
    current.host_port = ports.host;
    current.asleep = false;
    store.save(current) catch {};
}

/// Stops an idle service. The route is updated last, so that a request
/// arriving during the stop stays parked instead of hitting a dying process.
pub fn sleep(store: Store, eng: *Engine, id: []const u8) void {
    defer store.syncRoutes();
    const svc = store.load(id) catch return;
    if (svc.container.len == 0) return;
    eng.stop(svc.container, 10);

    const lock = store.lock() catch return;
    defer store.unlock(lock);
    var current = store.load(id) catch return;
    if (!std.mem.eql(u8, current.container, svc.container)) return;
    current.asleep = true;
    store.save(current) catch {};
}

/// Copies a project's service definitions into a new environment, without
/// their deployments or hostnames: those belong to the environment they came from.
pub fn duplicateEnvironment(store: Store, project: []const u8, from: []const u8, to: []const u8) !usize {
    const lock = try store.lock();
    defer store.unlock(lock);
    try store.ensureEnvironment(project, to);
    var count: usize = 0;
    for (try store.listIn(project, from)) |svc| {
        var copy = svc;
        copy.environment = to;
        copy.domains = &.{};
        copy.container = "";
        copy.host_port = 0;
        copy.asleep = false;
        copy.deployment = 0;
        copy.deployed_at = 0;
        if (store.exists(store.idOf(copy))) continue;
        try store.save(copy);
        count += 1;
    }
    return count;
}
