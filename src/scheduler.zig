//! Runs cron services and scheduled backups. It lives in the panel's process,
//! wakes once a minute, and starts each job as a separate `pharbor` process.
//!
//!   <root>/cron/<service id>.json   the last run: start, end, exit code
//!   <root>/cron/<service id>.log    what the runs printed

const std = @import("std");
const sys = @import("sys.zig");
const cron = @import("cron.zig");
const engine = @import("engine.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const linux = sys.linux;

/// Backups run at this hour, UTC; weekly ones on Sundays.
const backup_hour = 3;

pub const LastRun = struct {
    started_at: i64 = 0,
    finished_at: i64 = 0,
    exit_code: i32 = 0,
    /// The run before had not finished, so this one did not start.
    skipped: bool = false,
};

pub fn lastRunPath(store: Store, id: []const u8) []const u8 {
    return std.fmt.allocPrint(store.a, "{s}/cron/{s}.json", .{ store.root, id }) catch @panic("OOM");
}

pub fn logPath(store: Store, id: []const u8) []const u8 {
    return std.fmt.allocPrint(store.a, "{s}/cron/{s}.log", .{ store.root, id }) catch @panic("OOM");
}

pub fn lastRun(store: Store, id: []const u8) ?LastRun {
    const data = sys.readFileAlloc(store.a, lastRunPath(store, id), 4096) catch return null;
    return std.json.parseFromSliceLeaky(LastRun, store.a, data, .{ .ignore_unknown_fields = true }) catch null;
}

pub fn saveLastRun(store: Store, id: []const u8, last: LastRun) void {
    sys.mkdirP(store.path("cron"), 0o700) catch return;
    const data = std.json.Stringify.valueAlloc(store.a, last, .{}) catch return;
    sys.writeFileAtomic(lastRunPath(store, id), data, 0o600) catch {};
}

/// `pharbor <verb> <id>`, detached from the panel.
pub fn spawn(envp: engine.Envp, verb: [:0]const u8, id: []const u8) void {
    var buf: [512]u8 = undefined;
    const id_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{id}, 0) catch return;
    const argv = [_:null]?[*:0]const u8{ "pharbor", verb.ptr, id_z.ptr };
    const pid = sys.fork() catch return;
    if (pid == 0) {
        _ = linux.setsid();
        if ((sys.fork() catch linux.exit_group(1)) != 0) linux.exit_group(0);
        const null_fd = sys.open("/dev/null", sys.O_RDWR, 0) catch linux.exit_group(1);
        _ = linux.dup2(null_fd, 0);
        _ = linux.dup2(null_fd, 1);
        _ = linux.dup2(null_fd, 2);
        _ = linux.execve("/proc/self/exe", &argv, envp);
        linux.exit_group(127);
    }
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
}

fn nowS() i64 {
    return @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s));
}

fn tick(root: []const u8, envp: engine.Envp, minute: i64) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const store: Store = .{ .a = arena.allocator(), .root = root };
    const when = cron.utc(minute * 60);
    const services = store.list() catch return;
    for (services) |svc| {
        const id = store.idOf(svc);
        if (svc.cron.len > 0 and svc.deployment > 0) {
            if (cron.Schedule.parse(svc.cron)) |schedule| {
                if (schedule.matches(when)) spawn(envp, "_cronrun", id);
            } else |_| {}
        }
        if (svc.volumes.len > 0 and when.hour == backup_hour and when.minute == 0) {
            const due = std.mem.eql(u8, svc.backup_schedule, "daily") or
                (std.mem.eql(u8, svc.backup_schedule, "weekly") and when.weekday == 0);
            if (due) spawn(envp, "_backupjob", id);
        }
    }
}

/// Never returns. Each minute is handled once, even if the clock moves.
pub fn run(root: []const u8, envp: engine.Envp) void {
    var last: i64 = @divFloor(nowS(), 60);
    while (true) {
        const now = nowS();
        // Wake just after the next minute starts.
        const wait_s = 60 - @mod(now, 60) + 1;
        sys.sleepMs(@intCast(wait_s * 1000));
        const minute = @divFloor(nowS(), 60);
        if (minute <= last) continue;
        // After a long sleep (a phone in its pocket), catch up a few minutes.
        var m = @max(last + 1, minute - 5);
        while (m <= minute) : (m += 1) tick(root, envp, m);
        last = minute;
    }
}
