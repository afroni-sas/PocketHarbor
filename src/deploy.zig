//! Replaces a service's container without dropping a request: the new one
//! must prove it is healthy before traffic moves, and the old one keeps
//! serving until it has. Every attempt is recorded with its own log.

const std = @import("std");
const sys = @import("sys.zig");
const net = @import("net.zig");
const engine = @import("engine.zig");
const store_mod = @import("store.zig");
const vars_mod = @import("vars.zig");
const crypto = @import("crypto.zig");
const github = @import("github.zig");
const detect = @import("detect.zig");
const backup = @import("backup.zig");
const Store = store_mod.Store;
const Service = store_mod.Service;
const Deployment = store_mod.Deployment;
const Engine = engine.Engine;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    project: []const u8 = store_mod.default_project,
    environment: []const u8 = store_mod.default_environment,
    image: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    root_dir: ?[]const u8 = null,
    auto_deploy: ?bool = null,
    build_command: ?[]const u8 = null,
    start_command: ?[]const u8 = null,
    pre_deploy: ?[]const u8 = null,
    volumes: []const []const u8 = &.{},
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
        error.BuildFailed => "the build failed",
        error.RepoNotFound => "the repository or branch was not found (private? set a GitHub token)",
        error.GitHubDenied => "GitHub refused the token",
        error.NoStartCommand => "no start command was found; set one",
        error.UnknownLanguage => "no Dockerfile, and the language was not recognised",
        error.BadRootDir => "the root directory is not in the repository",
        error.UnsafePath => "the archive tried to write outside its directory",
        error.PreDeployFailed => "the pre-deploy command failed",
        error.NoSuchDeployment => "there is no such deployment",
        error.ImageGone => "the image of that deployment no longer exists",
        else => @errorName(e),
    };
}

/// Merges what the CLI was given into the service's saved definition.
pub fn configure(store: Store, vars: vars_mod.Vars, name: []const u8, opts: Options) !Service {
    const a = store.a;
    const id = store.idFrom(opts.project, opts.environment, name);
    var svc: Service = if (store.exists(id))
        try store.load(id)
    else
        .{ .name = name, .project = opts.project, .environment = opts.environment };
    if (opts.image) |i| {
        svc.image = i;
        svc.repo = "";
    }
    if (opts.repo) |r| {
        svc.repo = r;
        svc.image = "";
    }
    if (opts.branch) |b| svc.branch = b;
    if (opts.root_dir) |d| svc.root_dir = d;
    if (opts.auto_deploy) |v| svc.auto_deploy = v;
    if (opts.build_command) |v| svc.build_command = v;
    if (opts.start_command) |v| svc.start_command = v;
    if (opts.pre_deploy) |v| svc.pre_deploy = v;
    if (opts.volumes.len > 0) {
        var vols: std.ArrayList(store_mod.Volume) = .empty;
        try vols.appendSlice(a, svc.volumes);
        outer: for (opts.volumes) |mount| {
            for (vols.items) |v| if (std.mem.eql(u8, v.mount, mount)) continue :outer;
            try vols.append(a, .{ .name = backup.nameFromMount(mount), .mount = mount });
        }
        svc.volumes = vols.items;
    }
    if (opts.port) |p| svc.port = p;
    if (opts.health_path) |p| svc.health_path = p;
    if (opts.sleep_after_s) |s| svc.sleep_after_s = s;

    var set: std.ArrayList(vars_mod.Var) = .empty;
    for (opts.env) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse return error.BadEnv;
        try set.append(a, .{ .name = e[0..eq], .value = e[eq + 1 ..] });
    }

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
    // Includes variables kept in the service from before they had a store.
    const current = try vars.get(svc.project, svc.environment, svc.name);
    try vars.put(svc.project, svc.environment, svc.name, try vars_mod.merge(a, current, set.items, &.{}));
    svc.env = &.{};
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
    /// For downloads from GitHub.
    gpa: Allocator,
    io: std.Io,
    trigger: []const u8 = "cli",
    github_api: []const u8 = "",
    /// Runs the image of this earlier deployment again instead of building.
    from: ?u32 = null,
    /// With `from`: also run it with the variables it had, as a rollback.
    restore_env: bool = false,
    echo: bool = true,
    timeout_s: u32 = default_timeout_s,
};

/// Ships the service's saved definition.
pub fn run(store: Store, eng: *Engine, vars: vars_mod.Vars, id: []const u8, opts: RunOptions) !void {
    const a = store.a;
    const service_lock = try lockService(store, id);
    defer sys.close(service_lock);

    var svc = try store.load(id);
    if (svc.image.len == 0 and svc.repo.len == 0) {
        sys.eprint("error: {s} has nothing to run yet; pass --image or --repo\n", .{svc.name});
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
        .image = if (svc.repo.len > 0) svc.repo else svc.image,
        .trigger = opts.trigger,
        .container = container,
        .created_at = nowS(),
    };
    var source: ?Deployment = null;
    if (opts.from) |n| {
        source = store.loadDeployment(id, n) catch {
            sys.eprint("error: {s} has no deployment {d}\n", .{ svc.name, n });
            return error.NoSuchDeployment;
        };
        record.image = source.?.image;
        record.commit = source.?.commit;
        record.message = source.?.message;
    }
    try store.saveDeployment(id, record);
    const log = try Log.open(store, id, number, opts.echo);
    defer sys.close(log.fd);
    log.say("Deployment {d} of {s}: {s}", .{ number, svc.name, record.image });
    if (source) |s| log.say("{s} of deployment {d}", .{ if (opts.restore_env) "Rollback to the image and variables" else "Redeploy of the image", s.number });

    ship(store, eng, vars, id, &svc, &record, log, opts) catch |e| {
        log.say("Deployment failed: {s}", .{explain(e)});
        record.status = "failed";
        record.reason = explain(e);
        record.finished_at = nowS();
        store.saveDeployment(id, record) catch {};
        if (!opts.echo) return;
        return error.DeployFailed;
    };
}

fn ship(store: Store, eng: *Engine, vars: vars_mod.Vars, id: []const u8, svc: *Service, record: *Deployment, log: Log, opts: RunOptions) !void {
    const a = store.a;
    const container = record.container;
    eng.remove(container);

    var warnings: std.ArrayList([]const u8) = .empty;
    const env = if (opts.from != null and opts.restore_env)
        try loadSnapshot(store, vars, id, opts.from.?)
    else
        try vars.resolve(svc.*, &warnings);
    for (warnings.items) |w| log.say("warning: {s}", .{w});
    try saveSnapshot(store, vars, id, record.number, env);

    // A start command replaces what the image runs, unless the generated
    // Dockerfile already carries it.
    var start_override = svc.start_command.len > 0;
    if (opts.from != null) {
        // An image built here may have been pruned; a pulled one comes back.
        if (std.mem.startsWith(u8, record.image, "pharbor-")) {
            const listed = try eng.output(&.{"images"});
            const tag_start = std.mem.lastIndexOfScalar(u8, record.image, ':') orelse record.image.len;
            if (std.mem.indexOf(u8, listed.text, record.image[0..tag_start]) == null) return error.ImageGone;
        }
        start_override = start_override and !std.mem.startsWith(u8, record.image, "pharbor-");
    } else if (svc.repo.len > 0) {
        const built = try build(store, eng, vars, id, svc, record, log, opts, env);
        record.image = built.image;
        start_override = start_override and !built.generated;
        try store.saveDeployment(id, record.*);
    }

    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "run", "-d", "--name", container, "--restart", "always", "--hostname", store.publicLabel(svc.*) });
    var has_port = false;
    for (env) |v| has_port = has_port or std.mem.eql(u8, v.name, "PORT");
    if (!has_port) {
        try args.appendSlice(a, &.{ "-e", try std.fmt.allocPrint(a, "PORT={d}", .{if (svc.port != 0) svc.port else default_port}) });
    }
    for (env) |v| try args.appendSlice(a, &.{ "-e", try std.fmt.allocPrint(a, "{s}={s}", .{ v.name, v.value }) });
    const mounts = try volumeArgs(store, id, svc.*);
    try args.appendSlice(a, mounts);
    if (start_override) try args.appendSlice(a, &.{ "--entrypoint", "sh" });
    try args.append(a, record.image);
    if (start_override) try args.appendSlice(a, &.{ "-c", svc.start_command });

    if (svc.pre_deploy.len > 0) {
        log.say("Running the pre-deploy command: {s}", .{svc.pre_deploy});
        var pre: std.ArrayList([]const u8) = .empty;
        const pre_name = try std.fmt.allocPrint(a, "{s}-pre", .{container});
        eng.remove(pre_name);
        try pre.appendSlice(a, &.{ "run", "--rm", "--name", pre_name, "--hostname", store.publicLabel(svc.*) });
        try pre.appendSlice(a, mounts);
        for (env) |v| try pre.appendSlice(a, &.{ "-e", try std.fmt.allocPrint(a, "{s}={s}", .{ v.name, v.value }) });
        try pre.appendSlice(a, &.{ "--entrypoint", "sh", record.image, "-c", svc.pre_deploy });
        if (try eng.runTo(pre.items, log.fd) != 0) return error.PreDeployFailed;
    }

    // Two versions must not write to one volume at once, so a service with
    // volumes has a short gap between them, as on Railway.
    var paused: []const u8 = "";
    if (svc.volumes.len > 0) {
        const current = try store.load(id);
        if (current.container.len > 0) {
            if (eng.inspect(current.container)) |info| {
                if (info.alive()) {
                    log.say("Stopping {s} first: it holds the volumes", .{current.container});
                    eng.stop(current.container, 30);
                    paused = current.container;
                }
            }
        }
    }
    errdefer if (paused.len > 0) {
        log.say("Starting {s} again", .{paused});
        _ = eng.start(paused);
    };

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
    pruneImages(store, eng, id);

    if (old.len > 0 and !std.mem.eql(u8, old, container)) {
        sys.sleepMs(drain_ms);
        eng.stop(old, 10);
        eng.remove(old);
    }
    log.say("Deployed {s}", .{svc.name});
}

const Built = struct { image: []const u8, generated: bool };

/// Fetches the commit at the tip of the branch, and builds it.
fn build(store: Store, eng: *Engine, vars: vars_mod.Vars, id: []const u8, svc: *Service, record: *Deployment, log: Log, opts: RunOptions, env: []const vars_mod.Var) !Built {
    const a = store.a;
    const s = store.settings();
    const token = if (s.github_token.len > 0) try crypto.open(a, vars.key, s.github_token) else "";
    var client: github.Client = .{ .gpa = opts.gpa, .io = opts.io, .token = token };
    if (opts.github_api.len > 0) client.api = opts.github_api;

    log.say("Fetching {s}@{s}", .{ svc.repo, svc.branch });
    const commit = try client.latestCommit(a, svc.repo, svc.branch);
    record.commit = commit.sha[0..@min(7, commit.sha.len)];
    record.message = commit.message;
    try store.saveDeployment(id, record.*);
    log.say("Commit {s}: {s}", .{ record.commit, record.message });

    const dir = try std.fmt.allocPrint(a, "{s}/builds/{s}-{d}", .{ store.root, id, record.number });
    sys.rmrf(dir) catch {};
    try sys.mkdirP(dir, 0o700);
    defer sys.rmrf(dir) catch {};
    const archive = try std.fmt.allocPrint(a, "{s}/source.tar.gz", .{dir});
    try client.tarball(a, svc.repo, commit.sha, archive);
    const src = try std.fmt.allocPrint(a, "{s}/src", .{dir});
    const files = try github.extract(opts.gpa, opts.io, archive, src);
    log.say("Fetched {d} files", .{files});

    if (std.mem.indexOf(u8, svc.root_dir, "..") != null) return error.BadRootDir;
    const context = if (svc.root_dir.len > 0)
        try std.fmt.allocPrint(a, "{s}/{s}", .{ src, std.mem.trim(u8, svc.root_dir, "/") })
    else
        src;
    var cp = try sys.Path.of(context);
    if (!sys.exists(cp.z())) return error.BadRootDir;

    var dockerfile = try std.fmt.allocPrint(a, "{s}/Dockerfile", .{context});
    var generated = false;
    var dp = try sys.Path.of(dockerfile);
    if (sys.exists(dp.z())) {
        log.say("Building with the repository's Dockerfile", .{});
    } else {
        const plan = (try detect.detect(a, context, .{
            .build_command = svc.build_command,
            .start_command = svc.start_command,
        })) orelse return error.UnknownLanguage;
        dockerfile = try std.fmt.allocPrint(a, "{s}/Dockerfile.pharbor", .{context});
        try sys.writeFile(dockerfile, plan.dockerfile, 0o600);
        generated = true;
        log.say("Detected {s}. Generated Dockerfile:", .{plan.language});
        log.raw(plan.dockerfile);
        if (plan.port != 0 and svc.port == 0) svc.port = plan.port;
    }

    const tag = try std.fmt.allocPrint(a, "pharbor-{s}:{d}", .{ id, record.number });
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "build", "-t", tag, "-f", dockerfile });
    // Like Railway, variables are available to ARG lines of the build.
    for (env) |v| try args.appendSlice(a, &.{ "--build-arg", try std.fmt.allocPrint(a, "{s}={s}", .{ v.name, v.value }) });
    try args.append(a, context);
    if (opts.echo) sys.print("Building (pharbor logs --deploy {d} {s} shows the output)\n", .{ record.number, svc.name });
    if (try eng.runTo(args.items, log.fd) != 0) return error.BuildFailed;
    log.say("Built {s}", .{tag});
    return .{ .image = tag, .generated = generated };
}

/// Removes a service with its container and the images built for it.
/// Callers hold the store lock.
pub fn forget(store: Store, eng: *Engine, vars: vars_mod.Vars, svc: Service) void {
    const id = store.idOf(svc);
    if (svc.container.len > 0) eng.remove(svc.container);
    backup.dropAll(store, id);
    if (store.listDeployments(id)) |all| {
        for (all) |d| {
            if (std.mem.startsWith(u8, d.image, "pharbor-")) _ = eng.output(&.{ "rmi", d.image }) catch {};
        }
    } else |_| {}
    vars.dropService(svc.project, svc.environment, svc.name);
    store.remove(id);
}

fn volumeArgs(store: Store, id: []const u8, svc: Service) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (svc.volumes) |v| {
        const dir = backup.volumeDir(store, id, v.name);
        try sys.mkdirP(dir, 0o755);
        try out.appendSlice(store.a, &.{ "-v", try std.fmt.allocPrint(store.a, "{s}:{s}", .{ dir, v.mount }) });
    }
    return out.items;
}

/// Built images are kept for the five latest deployments, for rollbacks.
fn pruneImages(store: Store, eng: *Engine, id: []const u8) void {
    const all = store.listDeployments(id) catch return;
    var kept: usize = 0;
    for (all) |d| {
        if (!std.mem.startsWith(u8, d.image, "pharbor-")) continue;
        kept += 1;
        if (kept > 5) _ = eng.output(&.{ "rmi", d.image }) catch {};
    }
}

fn loadSnapshot(store: Store, vars: vars_mod.Vars, id: []const u8, number: u32) ![]vars_mod.Var {
    const file = try std.fmt.allocPrint(store.a, "{s}/{d}.env", .{ store.deploymentDir(id), number });
    const sealed = sys.readFileAlloc(store.a, file, 1 << 22) catch return error.NoSuchDeployment;
    const json = try crypto.open(store.a, vars.key, sealed);
    return std.json.parseFromSliceLeaky([]vars_mod.Var, store.a, json, .{});
}

/// What a deployment ran with, so that it can be run again exactly.
fn saveSnapshot(store: Store, vars: vars_mod.Vars, id: []const u8, number: u32, env: []const vars_mod.Var) !void {
    const json = try std.json.Stringify.valueAlloc(store.a, env, .{});
    const sealed = try crypto.seal(store.a, vars.key, json);
    const file = try std.fmt.allocPrint(store.a, "{s}/{d}.env", .{ store.deploymentDir(id), number });
    try sys.writeFileAtomic(file, sealed, 0o600);
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
pub fn duplicateEnvironment(store: Store, vars: vars_mod.Vars, project: []const u8, from: []const u8, to: []const u8) !usize {
    const lock = try store.lock();
    defer store.unlock(lock);
    try store.ensureEnvironment(project, to);
    vars.copyEnvironment(project, from, to);
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
