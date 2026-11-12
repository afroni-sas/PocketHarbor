//! Drives containers through the `pdock` command line.

const std = @import("std");
const sys = @import("sys.zig");
const linux = sys.linux;
const Allocator = std.mem.Allocator;

pub const Envp = [*:null]const ?[*:0]const u8;

pub const PortEntry = struct { container: u16, host: u16 };

pub const Info = struct {
    status: []const u8 = "",
    exit_code: i32 = 0,
    restarts: u32 = 0,
    ports: []const PortEntry = &.{},

    pub fn running(self: Info) bool {
        return std.mem.eql(u8, self.status, "running");
    }

    pub fn alive(self: Info) bool {
        return self.running() or std.mem.eql(u8, self.status, "restarting");
    }

    pub fn hostPort(self: Info, container: u16) ?u16 {
        for (self.ports) |p| {
            if (p.container == container) return p.host;
        }
        return null;
    }
};

pub const Output = struct { code: u8, text: []const u8 };

/// Finds `pdock`: `$PDOCK_BIN`, next to this program, then on `$PATH`.
pub fn locate(a: Allocator, env: *std.process.Environ.Map) ![:0]const u8 {
    if (env.get("PDOCK_BIN")) |p| return a.dupeSentinel(u8, p, 0);
    var buf: [sys.PATH_MAX]u8 = undefined;
    if (sys.readlink("/proc/self/exe", &buf)) |exe| {
        const dir = std.fs.path.dirname(exe) orelse ".";
        const near = try std.fmt.allocPrintSentinel(a, "{s}/pdock", .{dir}, 0);
        if (sys.exists(near.ptr)) return near;
    } else |_| {}
    var it = std.mem.tokenizeScalar(u8, env.get("PATH") orelse "", ':');
    while (it.next()) |dir| {
        const candidate = try std.fmt.allocPrintSentinel(a, "{s}/pdock", .{dir}, 0);
        if (sys.exists(candidate.ptr)) return candidate;
    }
    sys.eprint("error: pdock not found; install it or set PDOCK_BIN\n", .{});
    return error.EngineNotFound;
}

pub const Engine = struct {
    a: Allocator,
    bin: [:0]const u8,
    envp: Envp,

    fn argvZ(self: *Engine, args: []const []const u8) ![:null]?[*:0]const u8 {
        const out = try self.a.allocSentinel(?[*:0]const u8, args.len + 1, null);
        out[0] = "pdock";
        for (args, 0..) |s, i| out[i + 1] = (try self.a.dupeSentinel(u8, s, 0)).ptr;
        return out;
    }

    fn exitCode(status: i32) u8 {
        const s: u32 = @bitCast(status);
        if (linux.W.IFEXITED(s)) return linux.W.EXITSTATUS(s);
        return 128;
    }

    /// Runs `pdock` with this terminal attached, so its progress is visible.
    pub fn run(self: *Engine, args: []const []const u8) !u8 {
        const argv = try self.argvZ(args);
        const pid = try sys.fork();
        if (pid == 0) {
            _ = linux.execve(self.bin.ptr, argv.ptr, self.envp);
            linux.exit_group(127);
        }
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        return exitCode(status);
    }

    /// Runs `pdock` with its output going to `fd`, a deployment's log.
    pub fn runTo(self: *Engine, args: []const []const u8, fd: i32) !u8 {
        const argv = try self.argvZ(args);
        const pid = try sys.fork();
        if (pid == 0) {
            const null_fd = sys.open("/dev/null", sys.O_RDWR, 0) catch linux.exit_group(127);
            _ = linux.dup2(null_fd, 0);
            _ = linux.dup2(fd, 1);
            _ = linux.dup2(fd, 2);
            _ = linux.execve(self.bin.ptr, argv.ptr, self.envp);
            linux.exit_group(127);
        }
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        return exitCode(status);
    }

    /// Runs `pdock` with `input` on its stdin, for secrets that must not
    /// appear in a process listing. Returns what it printed.
    pub fn outputWithInput(self: *Engine, args: []const []const u8, input: []const u8) !Output {
        const argv = try self.argvZ(args);
        var in_pipe: [2]i32 = undefined;
        var out_pipe: [2]i32 = undefined;
        _ = try sys.ck(linux.pipe2(&in_pipe, .{ .CLOEXEC = true }));
        _ = try sys.ck(linux.pipe2(&out_pipe, .{ .CLOEXEC = true }));
        const pid = try sys.fork();
        if (pid == 0) {
            _ = linux.dup2(in_pipe[0], 0);
            _ = linux.dup2(out_pipe[1], 1);
            _ = linux.dup2(out_pipe[1], 2);
            _ = linux.execve(self.bin.ptr, argv.ptr, self.envp);
            linux.exit_group(127);
        }
        sys.close(in_pipe[0]);
        sys.close(out_pipe[1]);
        sys.writeAll(in_pipe[1], input) catch {};
        sys.close(in_pipe[1]);
        defer sys.close(out_pipe[0]);
        var text: std.ArrayList(u8) = .empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = sys.read(out_pipe[0], &buf) catch break;
            if (n == 0) break;
            try text.appendSlice(self.a, buf[0..n]);
        }
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        return .{ .code = exitCode(status), .text = text.items };
    }

    pub fn registries(self: *Engine) []const []const u8 {
        const out = self.output(&.{ "login", "--list" }) catch return &.{};
        if (out.code != 0) return &.{};
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, out.text, '\n');
        while (it.next()) |h| list.append(self.a, h) catch break;
        return list.items;
    }

    /// Runs `pdock` and returns what it printed.
    pub fn output(self: *Engine, args: []const []const u8) !Output {
        const argv = try self.argvZ(args);
        var pipe: [2]i32 = undefined;
        _ = try sys.ck(linux.pipe2(&pipe, .{ .CLOEXEC = true }));
        const pid = try sys.fork();
        if (pid == 0) {
            _ = linux.dup2(pipe[1], 1);
            _ = linux.dup2(pipe[1], 2);
            _ = linux.execve(self.bin.ptr, argv.ptr, self.envp);
            linux.exit_group(127);
        }
        sys.close(pipe[1]);
        defer sys.close(pipe[0]);
        var text: std.ArrayList(u8) = .empty;
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = sys.read(pipe[0], &buf) catch break;
            if (n == 0) break;
            try text.appendSlice(self.a, buf[0..n]);
        }
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        return .{ .code = exitCode(status), .text = text.items };
    }

    pub fn inspect(self: *Engine, name: []const u8) ?Info {
        const out = self.output(&.{ "inspect", name }) catch return null;
        if (out.code != 0) return null;
        const Doc = struct { state: Info = .{} };
        const doc = std.json.parseFromSliceLeaky(Doc, self.a, out.text, .{ .ignore_unknown_fields = true }) catch return null;
        return doc.state;
    }

    pub fn start(self: *Engine, name: []const u8) bool {
        const out = self.output(&.{ "start", name }) catch return false;
        return out.code == 0;
    }

    pub fn restart(self: *Engine, name: []const u8) bool {
        const out = self.output(&.{ "restart", name }) catch return false;
        return out.code == 0;
    }

    /// The id of the image a container runs: the digest of its config.
    pub fn imageIdOf(self: *Engine, name: []const u8) []const u8 {
        const out = self.output(&.{ "inspect", name }) catch return "";
        if (out.code != 0) return "";
        const Doc = struct { config: struct { image_id: []const u8 = "" } = .{} };
        const doc = std.json.parseFromSliceLeaky(Doc, self.a, out.text, .{ .ignore_unknown_fields = true }) catch return "";
        return doc.config.image_id;
    }

    /// The command a container runs, as it was created.
    pub fn argvOf(self: *Engine, name: []const u8) ?[]const []const u8 {
        const out = self.output(&.{ "inspect", name }) catch return null;
        if (out.code != 0) return null;
        const Doc = struct { config: struct { argv: []const []const u8 = &.{} } = .{} };
        const doc = std.json.parseFromSliceLeaky(Doc, self.a, out.text, .{ .ignore_unknown_fields = true }) catch return null;
        return doc.config.argv;
    }

    pub fn stop(self: *Engine, name: []const u8, timeout_s: u32) void {
        const t = std.fmt.allocPrint(self.a, "{d}", .{timeout_s}) catch return;
        _ = self.output(&.{ "stop", "-t", t, name }) catch {};
    }

    pub fn remove(self: *Engine, name: []const u8) void {
        _ = self.output(&.{ "rm", "-f", name }) catch {};
    }

    pub fn logs(self: *Engine, name: []const u8) []const u8 {
        const out = self.output(&.{ "logs", name }) catch return "";
        return out.text;
    }
};
