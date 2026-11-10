//! PocketHarbor: deploy and serve applications from an Android phone.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const net = @import("net.zig");
const engine = @import("engine.zig");
const routes = @import("routes.zig");
const proxy = @import("proxy.zig");
const deploy = @import("deploy.zig");
const tunnel = @import("tunnel.zig");
const store_mod = @import("store.zig");
const api = @import("api.zig");
const httpd = @import("httpd.zig");
const crypto = @import("crypto.zig");
const auth_mod = @import("auth.zig");
const vars_mod = @import("vars.zig");
const dns = @import("dns.zig");
const github = @import("github.zig");
const backup = @import("backup.zig");
const Store = store_mod.Store;
const Engine = engine.Engine;
const Allocator = std.mem.Allocator;
const linux = sys.linux;

const version = "0.1.0";

const usage =
    \\PocketHarbor: deploy and serve applications from an Android phone.
    \\
    \\Usage: pharbor <command> [options]
    \\
    \\Serving
    \\  serve [-d] [--listen [ADDR:]PORT]  Run the HTTP proxy (default 0.0.0.0:8080)
    \\  install                            Start the proxy when the phone boots (Termux:Boot)
    \\
    \\Services
    \\  deploy NAME [options]              Deploy a new version without downtime
    \\      --project NAME, --env NAME     Where it belongs (default: default, production)
    \\      --image IMAGE                  Image to run
    \\      --repo OWNER/NAME              Build from GitHub instead
    \\      --branch NAME                  Branch to build and watch (default main)
    \\      --root-dir DIR                 Directory to build, for monorepos
    \\      --build-command CMD            Replaces the detected build step
    \\      --start-command CMD            Replaces what the image runs
    \\      --no-auto-deploy               Do not deploy on each push
    \\      --pre-deploy CMD               Runs in the new version before it takes traffic
    \\      --volume /PATH                 Data that survives deployments (repeatable)
    \\      --port N                       Port the app listens on (default: detect)
    \\      --domain NAME                  Hostname to answer for (repeatable)
    \\      -e, --env KEY=VALUE            Environment variable (repeatable)
    \\      --health PATH                  HTTP path that must answer 2xx or 3xx
    \\      --sleep-after TIME             Stop after this long idle, e.g. 10m; 0 is never
    \\      --timeout SEC                  Time allowed to become healthy (default 180)
    \\  ls [--project P] [--env E]         List services
    \\  rm NAME                            Remove a service
    \\  logs NAME [-f] [--tail N]          Application output
    \\  logs --http NAME [-f] [--tail N]   HTTP requests, as JSON lines
    \\  deployments NAME                   Deployment history
    \\  redeploy NAME                      The current image again, with current variables
    \\  rollback NAME N                    Deployment N again: its image and its variables
    \\  logs --deploy N NAME               The log of one deployment
    \\
    \\Volumes and backups
    \\  volume ls NAME                     Volumes and the space they use
    \\  volume rm NAME VOLUME              Deletes the volume and its data
    \\  backup create NAME [VOLUME] [--live]   --live does not stop the service
    \\  backup ls NAME | restore NAME VOLUME ID | rm NAME VOLUME ID
    \\  backup schedule NAME daily|weekly|off   Keeps the 7 latest
    \\
    \\Projects
    \\  project ls | create NAME | rm NAME
    \\  env ls [--project P]
    \\  env create NAME [--project P] [--from ENV]   Copies the services of ENV
    \\  env rm NAME [--project P]
    \\
    \\Commands that name a service also take --project and --env.
    \\
    \\Domains
    \\  domain add NAME HOSTNAME           Answer for a hostname (*.example.com works)
    \\  domain rm NAME HOSTNAME
    \\  domain ls
    \\  domain base [DOMAIN|--clear]       Give every service NAME.DOMAIN
    \\
    \\Variables (encrypted; values may use ${{ KEY }}, ${{ shared.KEY }}, ${{ svc.KEY }})
    \\  var ls NAME | var ls --shared
    \\  var set NAME KEY=VALUE... | var set --shared KEY=VALUE...
    \\  var unset NAME KEY... | var import NAME FILE.env
    \\
    \\Private registries (for images such as ghcr.io/you/app)
    \\  registry login HOST -u USER      Reads the password or token from stdin
    \\  registry ls | logout HOST
    \\
    \\GitHub
    \\  github token TOKEN|--clear         For private repositories
    \\  github webhook                     The secret to give GitHub, for deploys on push
    \\
    \\Accounts (the panel is at the phone's address, port 8080)
    \\  user add EMAIL                     Reads the password from stdin
    \\  user ls | rm EMAIL | reset-2fa EMAIL
    \\  token create NAME | ls | rm ID    API tokens: Authorization: Bearer ...
    \\
    \\Public access
    \\  tunnel quick NAME                  A temporary public URL, no account needed
    \\  tunnel start TOKEN                 A permanent Cloudflare tunnel
    \\  tunnel status
    \\  tunnel stop
    \\
    \\  version
    \\
    \\Environment: PHARBOR_ROOT (data directory), PDOCK_BIN (path to pdock),
    \\  PHARBOR_GITHUB_API (GitHub Enterprise: https://HOST/api/v3)
    \\
;

const Ctx = struct {
    a: Allocator,
    gpa: Allocator,
    store: Store,
    eng: *Engine,
    envp: engine.Envp,
    env: *std.process.Environ.Map,
    io: std.Io,
};

fn die(comptime f: []const u8, args: anytype) noreturn {
    sys.eprint("error: " ++ f ++ "\n", args);
    linux.exit_group(1);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn dataRoot(a: Allocator, env: *std.process.Environ.Map) ![]const u8 {
    if (env.get("PHARBOR_ROOT")) |r| return a.dupe(u8, r);
    const home = env.get("HOME") orelse "";
    if (home.len > 1) return std.fmt.allocPrint(a, "{s}/.pocketharbor", .{home});
    // `adb shell` has HOME=/, which is not writable.
    var buf: [sys.PATH_MAX]u8 = undefined;
    const n = try sys.ck(linux.getcwd(&buf, buf.len));
    return std.fmt.allocPrint(a, "{s}/.pocketharbor", .{buf[0 .. n - 1]});
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2 or eql(args[1], "help") or eql(args[1], "--help") or eql(args[1], "-h")) {
        sys.print("{s}", .{usage});
        return;
    }
    const cmd: []const u8 = args[1];
    const rest: []const [:0]const u8 = args[2..];
    if (eql(cmd, "version")) {
        sys.print("pharbor {s} (zig {s})\n", .{ version, builtin.zig_version_string });
        return;
    }

    const root = try dataRoot(a, init.environ_map);
    try sys.mkdirP(root, 0o700);
    const store = try Store.init(a, root);
    const block = try init.environ_map.createPosixBlock(a, .{});
    const envp: engine.Envp = @ptrCast(block.slice.ptr);
    const eng = try a.create(Engine);
    eng.* = .{ .a = a, .bin = try engine.locate(a, init.environ_map), .envp = envp };
    // Android has no resolv.conf; builds download from GitHub.
    const io = dns.wrapIo(init.io, init.environ_map.get("POCKETDOCK_DNS"));
    var ctx: Ctx = .{ .a = a, .gpa = init.gpa, .store = store, .eng = eng, .envp = envp, .env = init.environ_map, .io = io };

    const commands = .{
        .{ "serve", cmdServe },
        .{ "install", cmdInstall },
        .{ "deploy", cmdDeploy },
        .{ "ls", cmdLs },
        .{ "rm", cmdRm },
        .{ "logs", cmdLogs },
        .{ "domain", cmdDomain },
        .{ "deployments", cmdDeployments },
        .{ "redeploy", cmdRedeploy },
        .{ "rollback", cmdRollback },
        .{ "project", cmdProject },
        .{ "env", cmdEnv },
        .{ "tunnel", cmdTunnel },
        .{ "_wake", cmdWake },
        .{ "_sleep", cmdSleep },
        .{ "_deploy", cmdDeployJob },
        .{ "_panel", cmdPanel },
        .{ "user", cmdUser },
        .{ "token", cmdToken },
        .{ "var", cmdVar },
        .{ "github", cmdGithub },
        .{ "registry", cmdRegistry },
        .{ "volume", cmdVolume },
        .{ "backup", cmdBackup },
    };
    inline for (commands) |c| {
        if (eql(cmd, c[0])) {
            c[1](&ctx, rest) catch |e| {
                // Commands print their own explanation for these.
                if (e != error.DeployFailed and e != error.TunnelFailed) {
                    if (e == error.Sys) die("{s}: {s}", .{ cmd, @tagName(sys.last) });
                    die("{s}: {s}", .{ cmd, @errorName(e) });
                }
                linux.exit_group(1);
            };
            return;
        }
    }
    die("unknown command \"{s}\" (try: pharbor help)", .{cmd});
}

fn value(args: []const [:0]const u8, i: *usize) []const u8 {
    i.* += 1;
    if (i.* >= args.len) die("{s} needs a value", .{args[i.* - 1]});
    return args[i.*];
}

/// Seconds from `90`, `90s`, `10m`, `2h` or `1d`.
fn parseDuration(s: []const u8) !u32 {
    if (s.len == 0) return error.BadDuration;
    const unit: u32 = switch (s[s.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        '0'...'9' => return std.fmt.parseInt(u32, s, 10),
        else => return error.BadDuration,
    };
    return (try std.fmt.parseInt(u32, s[0 .. s.len - 1], 10)) * unit;
}

const Scope = struct {
    project: []const u8 = store_mod.default_project,
    environment: []const u8 = store_mod.default_environment,

    /// Handles --project and --env, wherever they appear.
    fn take(self: *Scope, args: []const [:0]const u8, i: *usize) bool {
        const o: []const u8 = args[i.*];
        if (eql(o, "--project")) {
            self.project = value(args, i);
            checkName(self.project);
            return true;
        }
        if (eql(o, "--env")) {
            self.environment = value(args, i);
            checkName(self.environment);
            return true;
        }
        return false;
    }

    fn id(self: Scope, c: *Ctx, name: []const u8) []const u8 {
        return c.store.idFrom(self.project, self.environment, name);
    }

    fn load(self: Scope, c: *Ctx, name: []const u8) store_mod.Service {
        return c.store.load(self.id(c, name)) catch die("no service named {s} in {s}/{s}", .{ name, self.project, self.environment });
    }
};

fn checkName(name: []const u8) void {
    if (!store_mod.validName(name)) die("invalid service name \"{s}\": use a-z, 0-9 and -", .{name});
}

fn checkDomain(d: []const u8) void {
    if (!store_mod.validDomain(d)) die("invalid hostname \"{s}\"", .{d});
}

fn lockProxy(c: *Ctx) !i32 {
    var p = try sys.Path.of(c.store.path("proxy.lock"));
    const fd = try sys.open(p.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_CLOEXEC, 0o600);
    const LOCK_EX = 2;
    const LOCK_NB = 4;
    if (linux.errno(linux.flock(fd, LOCK_EX | LOCK_NB)) != .SUCCESS) die("the proxy is already running", .{});
    return fd;
}

fn detach(c: *Ctx) void {
    const pid = sys.fork() catch die("cannot fork", .{});
    if (pid != 0) linux.exit_group(0);
    _ = linux.setsid();
    var log = sys.Path.of(c.store.path("proxy.log")) catch linux.exit_group(1);
    const out = sys.open(log.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND, 0o600) catch linux.exit_group(1);
    const null_fd = sys.open("/dev/null", sys.O_RDWR, 0) catch linux.exit_group(1);
    _ = linux.dup2(null_fd, 0);
    _ = linux.dup2(out, 1);
    _ = linux.dup2(out, 2);
}

/// Returns in a worker process, and starts another if that one dies. Without
/// the proxy every service is unreachable, whatever state the services are in.
fn keepAlive() void {
    while (true) {
        const pid = sys.fork() catch linux.exit_group(1);
        if (pid == 0) return;
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        const s: u32 = @bitCast(status);
        if (linux.W.IFEXITED(s) and linux.W.EXITSTATUS(s) == 0) linux.exit_group(0);
        sys.sleepMs(1000);
    }
}

/// Runs the panel next to the proxy, restarting it if it dies, and going away
/// with the proxy.
fn startPanel(c: *Ctx) void {
    const PR_SET_PDEATHSIG = 1;
    const pid = sys.fork() catch return;
    if (pid != 0) return;
    _ = linux.prctl(PR_SET_PDEATHSIG, @intFromEnum(linux.SIG.TERM), 0, 0, 0);
    while (true) {
        const worker = sys.fork() catch linux.exit_group(1);
        if (worker == 0) {
            _ = linux.prctl(PR_SET_PDEATHSIG, @intFromEnum(linux.SIG.TERM), 0, 0, 0);
            const argv = [_:null]?[*:0]const u8{ "pharbor", "_panel" };
            _ = linux.execve("/proc/self/exe", &argv, c.envp);
            linux.exit_group(127);
        }
        var status: i32 = 0;
        _ = linux.waitpid(worker, &status, 0);
        if (linux.getppid() == 1) linux.exit_group(0);
        sys.sleepMs(1000);
    }
}

fn cmdPanel(c: *Ctx, _: []const [:0]const u8) !void {
    const s = c.store.settings();
    const panel = try c.a.create(api.Panel);
    panel.* = .{
        .root = c.store.root,
        .io = c.io,
        .key = try crypto.loadKey(c.store.root),
        .pdock = c.eng.bin,
        .envp = c.envp,
    };
    try httpd.serve(.{ .ip = .{ 127, 0, 0, 1 }, .port = s.panel_port }, api.handle, panel);
}

/// `_deploy ID TRIGGER [N]`: run in the background for the panel.
fn cmdDeployJob(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len < 2) return;
    var opts = runOptions(c, args[1]);
    opts.echo = false;
    if (args.len == 3) {
        opts.from = std.fmt.parseInt(u32, args[2], 10) catch return;
        opts.restore_env = eql(args[1], "rollback");
    }
    deploy.run(c.store, c.eng, try varsFor(c), args[0], opts) catch {};
}

fn runOptions(c: *Ctx, trigger: []const u8) deploy.RunOptions {
    return .{ .gpa = c.gpa, .io = c.io, .trigger = trigger, .github_api = c.env.get("PHARBOR_GITHUB_API") orelse "" };
}

fn activeDeployment(c: *Ctx, id: []const u8) u32 {
    for (c.store.listDeployments(id) catch &.{}) |d| {
        if (eql(d.status, "active")) return d.number;
    }
    die("nothing is deployed yet", .{});
}

fn cmdRedeploy(c: *Ctx, args: []const [:0]const u8) !void {
    var scope: Scope = .{};
    var name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!scope.take(args, &i)) name = args[i];
    }
    const svc = scope.load(c, name orelse die("usage: pharbor redeploy NAME", .{}));
    const id = c.store.idOf(svc);
    var opts = runOptions(c, "redeploy");
    opts.from = activeDeployment(c, id);
    try deploy.run(c.store, c.eng, try varsFor(c), id, opts);
}

fn cmdRollback(c: *Ctx, args: []const [:0]const u8) !void {
    var scope: Scope = .{};
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!scope.take(args, &i)) try positional.append(c.a, args[i]);
    }
    if (positional.items.len != 2) die("usage: pharbor rollback NAME N", .{});
    const svc = scope.load(c, positional.items[0]);
    var opts = runOptions(c, "rollback");
    opts.from = std.fmt.parseInt(u32, positional.items[1], 10) catch die("N is a deployment number", .{});
    opts.restore_env = true;
    try deploy.run(c.store, c.eng, try varsFor(c), c.store.idOf(svc), opts);
}

fn varsFor(c: *Ctx) !vars_mod.Vars {
    return .{ .store = c.store, .key = try crypto.loadKey(c.store.root) };
}

fn cmdVar(c: *Ctx, args: []const [:0]const u8) !void {
    const usage_line = "usage: pharbor var ls|set|unset|import [NAME|--shared] ...";
    if (args.len == 0) die(usage_line, .{});
    const verb: []const u8 = args[0];
    var scope: Scope = .{};
    var shared = false;
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--shared")) {
            shared = true;
        } else if (!scope.take(args, &i)) {
            try positional.append(c.a, args[i]);
        }
    }
    var rest = positional.items;
    var service: ?[]const u8 = null;
    if (!shared) {
        if (rest.len == 0) die(usage_line, .{});
        _ = scope.load(c, rest[0]);
        service = rest[0];
        rest = rest[1..];
    }
    const vars = try varsFor(c);
    if (eql(verb, "ls")) {
        for (try vars.get(scope.project, scope.environment, service)) |v| sys.print("{s}={s}\n", .{ v.name, v.value });
        return;
    }
    var set: std.ArrayList(vars_mod.Var) = .empty;
    var unset: std.ArrayList([]const u8) = .empty;
    if (eql(verb, "set")) {
        for (rest) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse die("set needs KEY=VALUE", .{});
            try set.append(c.a, .{ .name = kv[0..eq], .value = kv[eq + 1 ..] });
        }
    } else if (eql(verb, "unset")) {
        try unset.appendSlice(c.a, rest);
    } else if (eql(verb, "import")) {
        if (rest.len != 1) die("usage: pharbor var import NAME FILE", .{});
        const text = sys.readFileAlloc(c.a, rest[0], 1 << 20) catch die("cannot read {s}", .{rest[0]});
        try set.appendSlice(c.a, vars_mod.parseDotenv(c.a, text) catch |e| die("{s}: {s}", .{ rest[0], @errorName(e) }));
    } else {
        die(usage_line, .{});
    }
    const lock = try c.store.lock();
    defer c.store.unlock(lock);
    const current = try vars.get(scope.project, scope.environment, service);
    vars.put(scope.project, scope.environment, service, try vars_mod.merge(c.a, current, set.items, unset.items)) catch |e| die("{s}", .{@errorName(e)});
    sys.print("Saved. Deploy for the change to take effect.\n", .{});
}

fn humanSize(a: Allocator, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    return (if (n >= 1 << 30)
        std.fmt.allocPrint(a, "{d:.1} GB", .{f / (1 << 30)})
    else if (n >= 1 << 20)
        std.fmt.allocPrint(a, "{d:.1} MB", .{f / (1 << 20)})
    else
        std.fmt.allocPrint(a, "{d:.1} KB", .{f / 1024})) catch "";
}

fn cmdVolume(c: *Ctx, args: []const [:0]const u8) !void {
    const usage_line = "usage: pharbor volume ls NAME | rm NAME VOLUME";
    var scope: Scope = .{};
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!scope.take(args, &i)) try positional.append(c.a, args[i]);
    }
    const p = positional.items;
    if (p.len < 2) die(usage_line, .{});
    var svc = scope.load(c, p[1]);
    const id = c.store.idOf(svc);
    if (eql(p[0], "ls")) {
        for (svc.volumes) |v| {
            sys.print("{s: <16}{s: <36}{s}\n", .{ v.name, v.mount, humanSize(c.a, backup.usage(backup.volumeDir(c.store, id, v.name))) });
        }
        return;
    }
    if (eql(p[0], "rm") and p.len == 3) {
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        svc = try c.store.load(id);
        var kept: std.ArrayList(store_mod.Volume) = .empty;
        var found = false;
        for (svc.volumes) |v| {
            if (eql(v.name, p[2])) found = true else try kept.append(c.a, v);
        }
        if (!found) die("{s} has no volume {s}", .{ svc.name, p[2] });
        svc.volumes = kept.items;
        try c.store.save(svc);
        try sys.rmrf(backup.volumeDir(c.store, id, p[2]));
        sys.print("Removed. Deploy for the container to stop using it.\n", .{});
        return;
    }
    die(usage_line, .{});
}

fn cmdBackup(c: *Ctx, args: []const [:0]const u8) !void {
    const usage_line = "usage: pharbor backup create NAME [VOLUME] [--live] | ls NAME | restore NAME VOLUME ID | rm NAME VOLUME ID | schedule NAME daily|weekly|off";
    var scope: Scope = .{};
    var live = false;
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--live")) {
            live = true;
        } else if (!scope.take(args, &i)) {
            try positional.append(c.a, args[i]);
        }
    }
    const p = positional.items;
    if (p.len < 2) die(usage_line, .{});
    var svc = scope.load(c, p[1]);
    const id = c.store.idOf(svc);
    const verb = p[0];
    if (eql(verb, "create")) {
        if (svc.volumes.len == 0) die("{s} has no volumes", .{svc.name});
        for (svc.volumes) |v| {
            if (p.len == 3 and !eql(v.name, p[2])) continue;
            const b = backup.create(c.store, c.eng, svc, v.name, !live) catch |e| die("backup of {s} failed: {s}", .{ v.name, @errorName(e) });
            sys.print("{s} {s} {s}\n", .{ v.name, b.id, humanSize(c.a, b.size) });
        }
    } else if (eql(verb, "ls")) {
        for (svc.volumes) |v| {
            for (try backup.list(c.store, id, v.name)) |b| {
                var ts: [40]u8 = undefined;
                sys.print("{s: <16}{s: <14}{s: <26}{s}\n", .{ v.name, b.id, sys.fmtTime(&ts, @as(i128, b.created_at) * std.time.ns_per_s), humanSize(c.a, b.size) });
            }
        }
    } else if (eql(verb, "restore") and p.len == 4) {
        backup.restore(c.store, c.eng, svc, p[2], p[3]) catch |e| die("restore failed: {s}", .{@errorName(e)});
        sys.print("Restored {s} from {s}\n", .{ p[2], p[3] });
    } else if (eql(verb, "rm") and p.len == 4) {
        backup.remove(c.store, id, p[2], p[3]) catch die("no such backup", .{});
    } else if (eql(verb, "schedule") and p.len == 3) {
        if (!eql(p[2], "daily") and !eql(p[2], "weekly") and !eql(p[2], "off")) die(usage_line, .{});
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        svc = try c.store.load(id);
        svc.backup_schedule = if (eql(p[2], "off")) "" else p[2];
        try c.store.save(svc);
    } else {
        die(usage_line, .{});
    }
}

fn cmdRegistry(c: *Ctx, args: []const [:0]const u8) !void {
    const usage_line = "usage: pharbor registry login HOST -u USER | ls | logout HOST";
    if (args.len == 0) die(usage_line, .{});
    if (eql(args[0], "ls")) {
        for (c.eng.registries()) |h| sys.print("{s}\n", .{h});
        return;
    }
    if (eql(args[0], "logout") and args.len == 2) {
        linux.exit_group(try c.eng.run(&.{ "logout", args[1] }));
    }
    if (eql(args[0], "login") and args.len == 4 and eql(args[2], "-u")) {
        sys.eprint("Password or token: ", .{});
        const secret = try readSecretLine(c);
        const out = try c.eng.outputWithInput(&.{ "login", args[1], "-u", args[3], "--password-stdin" }, secret);
        sys.print("{s}", .{out.text});
        linux.exit_group(out.code);
    }
    die(usage_line, .{});
}

fn cmdGithub(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len == 0) die("usage: pharbor github token TOKEN|--clear | webhook", .{});
    const key = try crypto.loadKey(c.store.root);
    const lock = try c.store.lock();
    defer c.store.unlock(lock);
    var s = c.store.settings();
    if (eql(args[0], "token") and args.len == 2) {
        s.github_token = if (eql(args[1], "--clear")) "" else try crypto.seal(c.a, key, args[1]);
        try c.store.saveSettings(s);
        return;
    }
    if (eql(args[0], "webhook")) {
        if (s.webhook_secret.len == 0) {
            var raw: [24]u8 = undefined;
            crypto.random(&raw);
            s.webhook_secret = try crypto.seal(c.a, key, try crypto.hex(c.a, &raw));
            try c.store.saveSettings(s);
        }
        sys.print(
            \\In the repository's settings on GitHub, add a webhook:
            \\  Payload URL:  https://YOUR-PUBLIC-HOSTNAME/__pharbor/webhooks/github
            \\  Content type: application/json
            \\  Secret:       {s}
            \\  Events:       just the push event
            \\
        , .{try crypto.open(c.a, key, s.webhook_secret)});
        return;
    }
    die("usage: pharbor github token TOKEN|--clear | webhook", .{});
}

fn authFor(c: *Ctx) !auth_mod.Auth {
    return .{ .store = c.store, .io = c.io, .key = try crypto.loadKey(c.store.root) };
}

fn readSecretLine(c: *Ctx) ![]const u8 {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = try sys.read(0, buf[len..]);
        if (n == 0) break;
        len += n;
        if (std.mem.indexOfScalar(u8, buf[0..len], '\n') != null) break;
    }
    const line = std.mem.trimEnd(u8, buf[0 .. std.mem.indexOfScalar(u8, buf[0..len], '\n') orelse len], "\r");
    return c.a.dupe(u8, line);
}

fn cmdUser(c: *Ctx, args: []const [:0]const u8) !void {
    const usage_line = "usage: pharbor user add EMAIL | ls | rm EMAIL | reset-2fa EMAIL";
    if (args.len == 0) die(usage_line, .{});
    const auth = try authFor(c);
    const verb: []const u8 = args[0];
    if (eql(verb, "ls")) {
        for (auth.users()) |u| sys.print("{s: <40}{s}\n", .{ u.email, if (u.totp_enabled) "2FA" else "" });
        return;
    }
    if (args.len != 2) die(usage_line, .{});
    if (eql(verb, "add")) {
        sys.eprint("Password: ", .{});
        const password = try readSecretLine(c);
        _ = auth.addUser(args[1], password) catch |e| die("{s}", .{@errorName(e)});
        sys.print("Added {s}\n", .{args[1]});
        return;
    }
    const user = auth.findUser(args[1]) orelse die("no account for {s}", .{args[1]});
    if (eql(verb, "rm")) {
        try auth.removeUser(user.id);
        auth.endAllSessions(user.id);
    } else if (eql(verb, "reset-2fa")) {
        // For someone who lost their phone: whoever runs this has the data anyway.
        try auth.disableTotp(user);
        auth.endAllSessions(user.id);
    } else {
        die(usage_line, .{});
    }
}

fn cmdToken(c: *Ctx, args: []const [:0]const u8) !void {
    const usage_line = "usage: pharbor token create NAME | ls | rm ID";
    if (args.len == 0) die(usage_line, .{});
    const auth = try authFor(c);
    const verb: []const u8 = args[0];
    if (eql(verb, "ls")) {
        for (auth.tokens()) |t| sys.print("{s: <14}{s: <30}{s}...\n", .{ t.id, t.name, t.hint });
    } else if (eql(verb, "create") and args.len == 2) {
        const made = try auth.createToken(args[1]);
        sys.print("{s}\n", .{made.token});
        sys.eprint("Shown once: store it now.\n", .{});
    } else if (eql(verb, "rm") and args.len == 2) {
        if (!try auth.removeToken(args[1])) die("no token {s}", .{args[1]});
    } else {
        die(usage_line, .{});
    }
}

/// Writes the Termux:Boot script that starts the proxy with the phone.
fn cmdInstall(c: *Ctx, _: []const [:0]const u8) !void {
    const prefix = c.env.get("PREFIX") orelse "";
    const home = c.env.get("HOME") orelse "";
    if (std.mem.indexOf(u8, prefix, "com.termux") == null or home.len < 2) {
        die("run this from Termux (with the Termux:Boot app installed)", .{});
    }
    var exe_buf: [sys.PATH_MAX]u8 = undefined;
    const exe = try sys.readlink("/proc/self/exe", &exe_buf);
    const dir = try std.fmt.allocPrint(c.a, "{s}/.termux/boot", .{home});
    try sys.mkdirP(dir, 0o700);
    const script = try std.fmt.allocPrint(c.a,
        \\#!{s}/bin/sh
        \\# Written by `pharbor install`.
        \\export PHARBOR_ROOT='{s}'
        \\export PDOCK_BIN='{s}'
        \\exec '{s}' serve -d
        \\
    , .{ prefix, c.store.root, c.eng.bin, exe });
    const path = try std.fmt.allocPrint(c.a, "{s}/pocketharbor", .{dir});
    try sys.writeFile(path, script, 0o700);
    var p = try sys.Path.of(path);
    try sys.chmod(p.z(), 0o700);
    sys.print("Installed {s}\nOpen the Termux:Boot app once so that Android lets it run at boot.\n", .{path});
}

fn cmdServe(c: *Ctx, args: []const [:0]const u8) !void {
    var addr: net.Addr = .{ .ip = .{ 0, 0, 0, 0 }, .port = c.store.settings().proxy_port };
    var background = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const o: []const u8 = args[i];
        if (eql(o, "-d") or eql(o, "--detach")) {
            background = true;
        } else if (eql(o, "--listen")) {
            addr = net.parseAddr(value(args, &i)) catch die("invalid address", .{});
        } else {
            die("unknown option \"{s}\" for serve", .{o});
        }
    }
    _ = try lockProxy(c);
    // Before detaching, so that a mistake is seen in the terminal.
    var probe = net.listenTcp(addr) catch |e| {
        if (sys.last == .ADDRINUSE) die("port {d} is already in use", .{addr.port});
        return e;
    };
    sys.close(probe);
    probe = -1;

    if (background) {
        detach(c);
        keepAlive();
    }
    startPanel(c);
    var s = c.store.settings();
    s.proxy_port = addr.port;
    try c.store.saveSettings(s);
    proxy.installSignals();
    try c.store.writeProxyPid();
    c.store.syncRoutes();

    var p: proxy.Proxy = .{
        .gpa = c.gpa,
        .a = c.a,
        .store = c.store,
        .envp = c.envp,
        .table = routes.Table.empty(c.gpa),
    };
    try p.run(addr);
    var pid = try sys.Path.of(c.store.path("proxy.pid"));
    sys.unlink(pid.z()) catch {};
    // Everything it holds goes away with the process.
    linux.exit_group(0);
}

fn cmdDeploy(c: *Ctx, args: []const [:0]const u8) !void {
    var opts: deploy.Options = .{};
    var run_opts = runOptions(c, "cli");
    var scope: Scope = .{};
    var name: ?[]const u8 = null;
    var domains: std.ArrayList([]const u8) = .empty;
    var env: std.ArrayList([]const u8) = .empty;
    var volumes: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const o: []const u8 = args[i];
        if (scope.take(args, &i)) {
            continue;
        } else if (eql(o, "--image")) {
            opts.image = value(args, &i);
        } else if (eql(o, "--repo")) {
            opts.repo = github.normalizeRepo(value(args, &i)) orelse die("--repo takes owner/name or a github.com URL", .{});
        } else if (eql(o, "--branch")) {
            opts.branch = value(args, &i);
        } else if (eql(o, "--root-dir")) {
            opts.root_dir = value(args, &i);
            if (std.mem.indexOf(u8, opts.root_dir.?, "..") != null) die("--root-dir must stay inside the repository", .{});
        } else if (eql(o, "--build-command")) {
            opts.build_command = value(args, &i);
        } else if (eql(o, "--start-command")) {
            opts.start_command = value(args, &i);
        } else if (eql(o, "--volume")) {
            const m = value(args, &i);
            if (!backup.validMount(m)) die("--volume takes an absolute path inside the container, like /data", .{});
            try volumes.append(c.a, m);
        } else if (eql(o, "--pre-deploy")) {
            opts.pre_deploy = value(args, &i);
        } else if (eql(o, "--no-auto-deploy")) {
            opts.auto_deploy = false;
        } else if (eql(o, "--port")) {
            opts.port = std.fmt.parseInt(u16, value(args, &i), 10) catch die("invalid port", .{});
        } else if (eql(o, "--domain")) {
            const d = value(args, &i);
            checkDomain(d);
            try domains.append(c.a, d);
        } else if (eql(o, "-e") or eql(o, "--env-var")) {
            const e = value(args, &i);
            if (std.mem.indexOfScalar(u8, e, '=') == null) die("-e needs KEY=VALUE", .{});
            try env.append(c.a, e);
        } else if (eql(o, "--health")) {
            opts.health_path = value(args, &i);
            if (opts.health_path.?.len > 0 and opts.health_path.?[0] != '/') die("--health needs a path starting with /", .{});
        } else if (eql(o, "--sleep-after")) {
            opts.sleep_after_s = parseDuration(value(args, &i)) catch die("invalid duration", .{});
        } else if (eql(o, "--timeout")) {
            run_opts.timeout_s = std.fmt.parseInt(u32, value(args, &i), 10) catch die("invalid timeout", .{});
        } else if (o.len > 0 and o[0] == '-') {
            die("unknown option \"{s}\" for deploy", .{o});
        } else if (name == null) {
            name = o;
        } else {
            die("unexpected argument \"{s}\"", .{o});
        }
    }
    const n = name orelse die("usage: pharbor deploy NAME --image IMAGE", .{});
    checkName(n);
    opts.project = scope.project;
    opts.environment = scope.environment;
    opts.domains = domains.items;
    opts.env = env.items;
    opts.volumes = volumes.items;
    const vars = try varsFor(c);
    const svc = try deploy.configure(c.store, vars, n, opts);
    try deploy.run(c.store, c.eng, vars, c.store.idOf(svc), run_opts);
}

fn cmdLs(c: *Ctx, args: []const [:0]const u8) !void {
    var scope: Scope = .{};
    var filtered = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!scope.take(args, &i)) die("unknown option \"{s}\" for ls", .{args[i]});
        filtered = true;
    }
    sys.print("{s: <28}{s: <18}{s: <30}{s: <12}{s: <7}{s}\n", .{ "NAME", "ENV", "IMAGE", "STATUS", "PORT", "HOSTNAMES" });
    const s = c.store.settings();
    for (try c.store.list()) |svc| {
        if (filtered and (!eql(svc.project, scope.project) or !eql(svc.environment, scope.environment))) continue;
        const info = if (svc.container.len > 0) c.eng.inspect(svc.container) else null;
        const status: []const u8 = if (svc.asleep) "asleep" else if (info) |d| d.status else "not deployed";
        const names = try c.store.hostnames(svc, s);
        const shown = if (eql(svc.project, store_mod.default_project))
            svc.name
        else
            try std.fmt.allocPrint(c.a, "{s}/{s}", .{ svc.project, svc.name });
        sys.print("{s: <28}{s: <18}{s: <30}{s: <12}{d: <7}{s}\n", .{
            shown,
            svc.environment,
            svc.image,
            status,
            svc.port,
            try std.mem.join(c.a, " ", names),
        });
    }
}

fn cmdRm(c: *Ctx, args: []const [:0]const u8) !void {
    var scope: Scope = .{};
    var name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!scope.take(args, &i)) name = args[i];
    }
    const n = name orelse die("usage: pharbor rm NAME", .{});
    const svc = scope.load(c, n);
    const lock = try c.store.lock();
    defer c.store.unlock(lock);
    deploy.forget(c.store, c.eng, try varsFor(c), svc);
    c.store.syncRoutes();
    sys.print("Removed {s}\n", .{svc.name});
}

fn cmdDeployments(c: *Ctx, args: []const [:0]const u8) !void {
    var scope: Scope = .{};
    var name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!scope.take(args, &i)) name = args[i];
    }
    const n = name orelse die("usage: pharbor deployments NAME", .{});
    const svc = scope.load(c, n);
    sys.print("{s: <6}{s: <11}{s: <10}{s: <34}{s}\n", .{ "#", "STATUS", "TRIGGER", "IMAGE", "REASON" });
    for (try c.store.listDeployments(c.store.idOf(svc))) |d| {
        sys.print("{d: <6}{s: <11}{s: <10}{s: <34}{s}\n", .{ d.number, d.status, d.trigger, d.image, d.reason });
    }
}

fn cmdProject(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len == 0) die("usage: pharbor project ls|create NAME|rm NAME", .{});
    const verb: []const u8 = args[0];
    if (eql(verb, "ls")) {
        for (try c.store.listProjects()) |p| sys.print("{s: <30}{s}\n", .{ p.name, try std.mem.join(c.a, " ", p.environments) });
        return;
    }
    if (args.len != 2) die("usage: pharbor project ls|create NAME|rm NAME", .{});
    const name: []const u8 = args[1];
    checkName(name);
    const lock = try c.store.lock();
    defer c.store.unlock(lock);
    if (eql(verb, "create")) {
        if (c.store.projectExists(name)) die("project {s} already exists", .{name});
        try c.store.ensureEnvironment(name, store_mod.default_environment);
    } else if (eql(verb, "rm")) {
        if (!c.store.projectExists(name)) die("no project named {s}", .{name});
        for (try c.store.list()) |svc| {
            if (eql(svc.project, name)) deploy.forget(c.store, c.eng, try varsFor(c), svc);
        }
        const p = try c.store.loadProject(name);
        for (p.environments) |e| (try varsFor(c)).dropEnvironment(name, e);
        c.store.removeProject(name);
        c.store.syncRoutes();
    } else {
        die("usage: pharbor project ls|create NAME|rm NAME", .{});
    }
}

fn cmdEnv(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len == 0) die("usage: pharbor env ls|create NAME|rm NAME", .{});
    const verb: []const u8 = args[0];
    var scope: Scope = .{};
    var from: []const u8 = store_mod.default_environment;
    var name: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--from")) {
            from = value(args, &i);
        } else if (!scope.take(args, &i)) {
            name = args[i];
        }
    }
    if (eql(verb, "ls")) {
        const p = c.store.loadProject(scope.project) catch die("no project named {s}", .{scope.project});
        for (p.environments) |e| sys.print("{s}\n", .{e});
        return;
    }
    const n = name orelse die("usage: pharbor env create|rm NAME", .{});
    checkName(n);
    if (eql(verb, "create")) {
        const copied = try deploy.duplicateEnvironment(c.store, try varsFor(c), scope.project, from, n);
        sys.print("Created {s} with {d} services from {s}\n", .{ n, copied, from });
    } else if (eql(verb, "rm")) {
        if (eql(n, store_mod.default_environment)) die("the production environment cannot be removed", .{});
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        for (try c.store.listIn(scope.project, n)) |svc| deploy.forget(c.store, c.eng, try varsFor(c), svc);
        (try varsFor(c)).dropEnvironment(scope.project, n);
        var p = try c.store.loadProject(scope.project);
        var kept: std.ArrayList([]const u8) = .empty;
        for (p.environments) |e| {
            if (!eql(e, n)) try kept.append(c.a, e);
        }
        p.environments = kept.items;
        try c.store.saveProject(p);
        c.store.syncRoutes();
    } else {
        die("usage: pharbor env ls|create NAME|rm NAME", .{});
    }
}

fn printTail(data: []const u8, n: usize) void {
    var count: usize = 0;
    var i = data.len;
    while (i > 0) : (i -= 1) {
        if (data[i - 1] == '\n') {
            count += 1;
            if (count > n) {
                sys.print("{s}", .{data[i..]});
                return;
            }
        }
    }
    sys.print("{s}", .{data});
}

fn cmdLogs(c: *Ctx, args: []const [:0]const u8) !void {
    var http_log = false;
    var follow = false;
    var tail: ?usize = null;
    var deployment: ?u32 = null;
    var name: ?[]const u8 = null;
    var scope: Scope = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const o: []const u8 = args[i];
        if (scope.take(args, &i)) {
            continue;
        } else if (eql(o, "--http")) {
            http_log = true;
        } else if (eql(o, "-f") or eql(o, "--follow")) {
            follow = true;
        } else if (eql(o, "--tail")) {
            tail = std.fmt.parseInt(usize, value(args, &i), 10) catch die("invalid --tail", .{});
        } else if (eql(o, "--deploy")) {
            deployment = std.fmt.parseInt(u32, value(args, &i), 10) catch die("invalid --deploy", .{});
        } else if (name == null) {
            name = o;
        } else {
            die("unexpected argument \"{s}\"", .{o});
        }
    }
    const n = name orelse die("usage: pharbor logs [--http] NAME", .{});
    const svc = scope.load(c, n);
    const id = c.store.idOf(svc);

    if (deployment) |number| {
        const data = sys.readFileAlloc(c.a, c.store.deploymentLog(id, number), 1 << 26) catch die("no such deployment", .{});
        sys.print("{s}", .{data});
        return;
    }
    if (!http_log) {
        var a: std.ArrayList([]const u8) = .empty;
        try a.append(c.a, "logs");
        if (follow) try a.append(c.a, "-f");
        if (tail) |t| try a.appendSlice(c.a, &.{ "--tail", try std.fmt.allocPrint(c.a, "{d}", .{t}) });
        try a.append(c.a, svc.container);
        linux.exit_group(try c.eng.run(a.items));
    }

    var p = try sys.Path.of(c.store.path(try std.fmt.allocPrint(c.a, "http/{s}.log", .{id})));
    const data = sys.readFileAlloc(c.a, p.slice(), 1 << 30) catch "";
    printTail(data, tail orelse 100);
    if (!follow) return;
    var offset = data.len;
    var buf: [65536]u8 = undefined;
    while (true) {
        sys.sleepMs(300);
        const fd = sys.open(p.z(), sys.O_CLOEXEC, 0) catch continue;
        defer sys.close(fd);
        var st: sys.Stat = undefined;
        sys.stat(p.z(), &st) catch continue;
        // The log was rotated underneath us.
        if (@as(u64, @intCast(st.size)) < offset) offset = 0;
        _ = linux.lseek(fd, @intCast(offset), 0);
        while (true) {
            const got = sys.read(fd, &buf) catch break;
            if (got == 0) break;
            sys.print("{s}", .{buf[0..got]});
            offset += got;
        }
    }
}

fn cmdDomain(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len == 0) die("usage: pharbor domain add|rm|ls|base", .{});
    const verb: []const u8 = args[0];
    if (eql(verb, "ls")) {
        const s = c.store.settings();
        if (s.base_domain.len > 0) sys.print("base: {s}\n", .{s.base_domain});
        for (try c.store.list()) |svc| {
            for (try c.store.hostnames(svc, s)) |h| sys.print("{s: <40}{s}\n", .{ h, svc.name });
        }
        return;
    }
    if (eql(verb, "base")) {
        var s = c.store.settings();
        if (args.len == 1) {
            sys.print("{s}\n", .{s.base_domain});
            return;
        }
        if (eql(args[1], "--clear")) {
            s.base_domain = "";
        } else {
            checkDomain(args[1]);
            s.base_domain = args[1];
        }
        const lock = try c.store.lock();
        defer c.store.unlock(lock);
        try c.store.saveSettings(s);
        c.store.syncRoutes();
        return;
    }
    var scope: Scope = .{};
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (!scope.take(args, &i)) try positional.append(c.a, args[i]);
    }
    if (positional.items.len != 2) die("usage: pharbor domain add|rm NAME HOSTNAME", .{});
    const host: []const u8 = positional.items[1];
    checkDomain(host);
    const lock = try c.store.lock();
    defer c.store.unlock(lock);
    var svc = scope.load(c, positional.items[0]);
    var out: std.ArrayList([]const u8) = .empty;
    var present = false;
    for (svc.domains) |d| {
        if (eql(d, host)) {
            present = true;
            if (eql(verb, "rm")) continue;
        }
        try out.append(c.a, d);
    }
    if (eql(verb, "add")) {
        if (present) return;
        for (try c.store.list()) |other| {
            for (other.domains) |d| {
                if (eql(d, host)) die("{s} already serves {s}", .{ other.name, host });
            }
        }
        try out.append(c.a, host);
    } else if (!eql(verb, "rm")) {
        die("usage: pharbor domain add|rm NAME HOSTNAME", .{});
    } else if (!present) {
        die("{s} does not serve {s}", .{ svc.name, host });
    }
    svc.domains = out.items;
    try c.store.save(svc);
    c.store.syncRoutes();
}

fn cmdTunnel(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len == 0) die("usage: pharbor tunnel quick NAME|start TOKEN|status|stop", .{});
    const verb: []const u8 = args[0];
    if (eql(verb, "quick") and args.len >= 2) {
        var scope: Scope = .{};
        var name: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (!scope.take(args, &i)) name = args[i];
        }
        const svc = scope.load(c, name orelse die("usage: pharbor tunnel quick NAME", .{}));
        return tunnel.quick(c.store, c.eng, c.store.idOf(svc));
    }
    if (eql(verb, "start") and args.len == 2) return tunnel.named(c.store, c.eng, args[1]);
    if (eql(verb, "status")) return tunnel.status(c.eng);
    if (eql(verb, "stop")) return tunnel.stop(c.store, c.eng);
    die("usage: pharbor tunnel quick NAME|start TOKEN|status|stop", .{});
}

fn cmdWake(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len == 1) deploy.wake(c.store, c.eng, args[0]);
}

fn cmdSleep(c: *Ctx, args: []const [:0]const u8) !void {
    if (args.len == 1) deploy.sleep(c.store, c.eng, args[0]);
}

test {
    _ = @import("tunnel.zig");
    _ = @import("crypto.zig");
    _ = @import("http.zig");
    _ = @import("routes.zig");
}
