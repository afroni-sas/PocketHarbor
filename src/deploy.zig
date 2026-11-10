//! Replaces a service's container without dropping a request: the new one
//! must prove it is healthy before traffic moves, and the old one keeps
//! serving until it has.

const std = @import("std");
const sys = @import("sys.zig");
const net = @import("net.zig");
const engine = @import("engine.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Service = store_mod.Service;
const Engine = engine.Engine;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    image: ?[]const u8 = null,
    port: ?u16 = null,
    domains: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    health_path: ?[]const u8 = null,
    sleep_after_s: ?u32 = null,
    timeout_s: u32 = 180,
};

/// In-flight requests finish on the old container during this time.
const drain_ms = 3000;
const default_port: u16 = 8080;

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
        else => @errorName(e),
    };
}

pub fn deploy(store: Store, eng: *Engine, name: []const u8, opts: Options) !void {
    const a = store.a;
    var svc: Service = if (store.exists(name)) try store.load(name) else .{ .name = name };
    if (opts.image) |i| svc.image = i;
    if (svc.image.len == 0) {
        sys.eprint("error: {s} has no image yet; pass --image\n", .{name});
        return error.NoImage;
    }
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

    const number = svc.deployment + 1;
    const container = try std.fmt.allocPrint(a, "{s}-{d}", .{ name, number });
    eng.remove(container);

    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "run", "-d", "--name", container, "--restart", "always" });
    if (!hasEnv(svc.env, "PORT")) {
        try args.appendSlice(a, &.{ "-e", try std.fmt.allocPrint(a, "PORT={d}", .{if (svc.port != 0) svc.port else default_port}) });
    }
    for (svc.env) |e| try args.appendSlice(a, &.{ "-e", e });
    try args.append(a, svc.image);

    sys.print("Deployment {d} of {s}: {s}\n", .{ number, name, svc.image });
    if (try eng.run(args.items) != 0) {
        sys.eprint("error: the container could not be started\n", .{});
        return error.DeployFailed;
    }

    const deadline = sys.monoNs() + @as(i128, opts.timeout_s) * std.time.ns_per_s;
    const ports = waitForPort(eng, container, svc.port, deadline) catch |e| return abort(eng, container, e);
    sys.print("Listening on port {d}, checking health\n", .{ports.container});
    waitHealthy(eng, container, ports.host, svc.health_path, deadline) catch |e| return abort(eng, container, e);

    const lock = try store.lock();
    var old: []const u8 = "";
    {
        defer store.unlock(lock);
        // Someone may have changed its domains while this was starting.
        if (store.exists(name)) {
            const current = try store.load(name);
            old = current.container;
            for (current.domains) |d| {
                var found = false;
                for (svc.domains) |have| found = found or std.mem.eql(u8, have, d);
                if (!found) try domains.append(a, d);
            }
            svc.domains = domains.items;
        }
        svc.container = container;
        svc.port = ports.container;
        svc.host_port = ports.host;
        svc.asleep = false;
        svc.deployment = number;
        svc.deployed_at = nowS();
        try store.save(svc);
        store.syncRoutes();
    }
    sys.print("Traffic moved to {s}\n", .{container});

    if (old.len > 0 and !std.mem.eql(u8, old, container)) {
        sys.sleepMs(drain_ms);
        eng.stop(old, 10);
        eng.remove(old);
    }
    sys.print("Deployed {s}\n", .{name});
}

/// Leaves the running version alone and says why the new one failed.
fn abort(eng: *Engine, container: []const u8, cause: anyerror) anyerror {
    sys.eprint("error: deployment failed: {s}\n", .{explain(cause)});
    const logs = eng.logs(container);
    const tail = lastLines(logs, 20);
    if (tail.len > 0) sys.eprint("--- last output of {s}\n{s}", .{ container, tail });
    eng.remove(container);
    return error.DeployFailed;
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
pub fn wake(store: Store, eng: *Engine, name: []const u8) void {
    defer store.syncRoutes();
    const svc = store.load(name) catch return;
    if (svc.container.len == 0) return;
    const info = eng.inspect(svc.container) orelse return;
    if (!info.alive() and !eng.start(svc.container)) return;
    const deadline = sys.monoNs() + 90 * std.time.ns_per_s;
    const ports = waitForPort(eng, svc.container, svc.port, deadline) catch return;
    waitHealthy(eng, svc.container, ports.host, svc.health_path, deadline) catch return;

    const lock = store.lock() catch return;
    defer store.unlock(lock);
    var current = store.load(name) catch return;
    if (!std.mem.eql(u8, current.container, svc.container)) return;
    current.host_port = ports.host;
    current.asleep = false;
    store.save(current) catch {};
}

/// Stops an idle service. The route is updated last, so that a request
/// arriving during the stop stays parked instead of hitting a dying process.
pub fn sleep(store: Store, eng: *Engine, name: []const u8) void {
    defer store.syncRoutes();
    const svc = store.load(name) catch return;
    if (svc.container.len == 0) return;
    eng.stop(svc.container, 10);

    const lock = store.lock() catch return;
    defer store.unlock(lock);
    var current = store.load(name) catch return;
    if (!std.mem.eql(u8, current.container, svc.container)) return;
    current.asleep = true;
    store.save(current) catch {};
}
