//! Volumes, and their backups.
//!
//!   <root>/volumes/<service id>/<volume>/          the data
//!   <root>/backups/<service id>/<volume>/<id>.tar.gz
//!
//! Archives are made and unpacked by `tar` in a small container, which sees
//! files the way the service does. By default the service is stopped for the
//! few seconds a backup takes, so that a database is copied in a consistent
//! state.

const std = @import("std");
const sys = @import("sys.zig");
const engine = @import("engine.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Service = store_mod.Service;
const Engine = engine.Engine;

const tool_image = "alpine:3.20";

pub const Backup = struct {
    id: []const u8,
    volume: []const u8,
    size: u64,
    created_at: i64,
};

pub fn volumeDir(store: Store, id: []const u8, volume: []const u8) []const u8 {
    return std.fmt.allocPrint(store.a, "{s}/volumes/{s}/{s}", .{ store.root, id, volume }) catch @panic("OOM");
}

fn backupDir(store: Store, id: []const u8, volume: []const u8) []const u8 {
    return std.fmt.allocPrint(store.a, "{s}/backups/{s}/{s}", .{ store.root, id, volume }) catch @panic("OOM");
}

/// A volume's name from where it is mounted: /var/lib/postgresql/data is "data".
pub fn nameFromMount(mount: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, mount, "/");
    const base = std.fs.path.basename(trimmed);
    return if (base.len == 0) "root" else base;
}

pub fn validMount(mount: []const u8) bool {
    if (mount.len < 2 or mount[0] != '/' or std.mem.indexOf(u8, mount, "..") != null) return false;
    inline for (.{ "/proc", "/sys", "/dev", "/etc/hosts", "/etc/resolv.conf", "/etc/hostname" }) |bad| {
        if (std.mem.eql(u8, mount, bad) or std.mem.startsWith(u8, mount, bad ++ "/")) return false;
    }
    return mount.len > 1;
}

/// Bytes used under `path`, files only.
pub fn usage(path: []const u8) u64 {
    var total: u64 = 0;
    var p = sys.Path.of(path) catch return 0;
    var it = sys.DirIter.open_(p.z()) catch return 0;
    defer it.deinit();
    while (it.next() catch null) |ent| {
        var child = sys.Path.join(path, "/") catch continue;
        child.append(ent.name) catch continue;
        var st: sys.Stat = undefined;
        sys.lstat(child.z(), &st) catch continue;
        if (sys.isDir(st.mode)) {
            total += usage(child.slice());
        } else {
            total += @intCast(st.size);
        }
    }
    return total;
}

fn nowS() i64 {
    return @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s));
}

fn stopFor(eng: *Engine, svc: Service, stop: bool) bool {
    if (!stop or svc.container.len == 0) return false;
    const info = eng.inspect(svc.container) orelse return false;
    if (!info.alive()) return false;
    eng.stop(svc.container, 30);
    return true;
}

pub fn create(store: Store, eng: *Engine, svc: Service, volume: []const u8, stop: bool) !Backup {
    const a = store.a;
    const id = store.idOf(svc);
    const data = volumeDir(store, id, volume);
    var dp = try sys.Path.of(data);
    if (!sys.exists(dp.z())) return error.NoSuchVolume;
    const dir = backupDir(store, id, volume);
    try sys.mkdirP(dir, 0o700);
    var stamp: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&stamp, "{d}", .{nowS()});

    const stopped = stopFor(eng, svc, stop);
    defer if (stopped) {
        _ = eng.start(svc.container);
    };
    const out = try eng.output(&.{
        "run",                                            "--rm", "--network", "none",
        "-v",                                             try std.fmt.allocPrint(a, "{s}:/data:ro", .{data}),
        "-v",                                             try std.fmt.allocPrint(a, "{s}:/backup", .{dir}),
        tool_image,                                       "tar",  "czf",       try std.fmt.allocPrint(a, "/backup/{s}.tar.gz", .{name}),
        "-C",                                             "/data", ".",
    });
    if (out.code != 0) {
        sys.eprint("{s}", .{out.text});
        return error.BackupFailed;
    }
    var st: sys.Stat = undefined;
    var ap = try sys.Path.of(try std.fmt.allocPrint(a, "{s}/{s}.tar.gz", .{ dir, name }));
    try sys.stat(ap.z(), &st);
    return .{ .id = try a.dupe(u8, name), .volume = volume, .size = @intCast(st.size), .created_at = nowS() };
}

/// Newest first.
pub fn list(store: Store, id: []const u8, volume: []const u8) ![]Backup {
    const a = store.a;
    var out: std.ArrayList(Backup) = .empty;
    const dir = backupDir(store, id, volume);
    var dp = sys.Path.of(dir) catch return out.items;
    var it = sys.DirIter.open_(dp.z()) catch return out.items;
    defer it.deinit();
    while (try it.next()) |ent| {
        if (!std.mem.endsWith(u8, ent.name, ".tar.gz")) continue;
        const bid = ent.name[0 .. ent.name.len - 7];
        var st: sys.Stat = undefined;
        var p = try sys.Path.of(try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, ent.name }));
        sys.stat(p.z(), &st) catch continue;
        try out.append(a, .{
            .id = try a.dupe(u8, bid),
            .volume = volume,
            .size = @intCast(st.size),
            .created_at = std.fmt.parseInt(i64, bid, 10) catch 0,
        });
    }
    std.mem.sort(Backup, out.items, {}, struct {
        fn lt(_: void, x: Backup, y: Backup) bool {
            return x.created_at > y.created_at;
        }
    }.lt);
    return out.items;
}

fn validId(bid: []const u8) bool {
    if (bid.len == 0 or bid.len > 20) return false;
    for (bid) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// Replaces the volume's contents with a backup. The service is stopped
/// meanwhile and started again after.
pub fn restore(store: Store, eng: *Engine, svc: Service, volume: []const u8, bid: []const u8) !void {
    const a = store.a;
    if (!validId(bid)) return error.NoSuchBackup;
    const id = store.idOf(svc);
    const dir = backupDir(store, id, volume);
    var ap = try sys.Path.of(try std.fmt.allocPrint(a, "{s}/{s}.tar.gz", .{ dir, bid }));
    if (!sys.exists(ap.z())) return error.NoSuchBackup;
    const data = volumeDir(store, id, volume);

    const stopped = stopFor(eng, svc, true);
    defer if (stopped) {
        _ = eng.start(svc.container);
    };
    // Unpacked beside the volume first, so that a failure leaves it intact.
    const staging = try std.fmt.allocPrint(a, "{s}.restore", .{data});
    sys.rmrf(staging) catch {};
    try sys.mkdirP(staging, 0o755);
    const out = try eng.output(&.{
        "run",                                             "--rm", "--network", "none",
        "-v",                                              try std.fmt.allocPrint(a, "{s}:/data", .{staging}),
        "-v",                                              try std.fmt.allocPrint(a, "{s}:/backup:ro", .{dir}),
        tool_image,                                        "tar",  "xzf",       try std.fmt.allocPrint(a, "/backup/{s}.tar.gz", .{bid}),
        "-C",                                              "/data",
    });
    if (out.code != 0) {
        sys.rmrf(staging) catch {};
        sys.eprint("{s}", .{out.text});
        return error.RestoreFailed;
    }
    const old = try std.fmt.allocPrint(a, "{s}.old", .{data});
    sys.rmrf(old) catch {};
    var dp = try sys.Path.of(data);
    var op = try sys.Path.of(old);
    var sp = try sys.Path.of(staging);
    if (sys.exists(dp.z())) try sys.rename(dp.z(), op.z());
    try sys.rename(sp.z(), dp.z());
    sys.rmrf(old) catch {};
}

pub fn remove(store: Store, id: []const u8, volume: []const u8, bid: []const u8) !void {
    if (!validId(bid)) return error.NoSuchBackup;
    var p = try sys.Path.of(try std.fmt.allocPrint(store.a, "{s}/{s}.tar.gz", .{ backupDir(store, id, volume), bid }));
    sys.unlink(p.z()) catch return error.NoSuchBackup;
}

/// Keeps the `keep` newest backups of a volume.
pub fn prune(store: Store, id: []const u8, volume: []const u8, keep: usize) void {
    const all = list(store, id, volume) catch return;
    if (all.len <= keep) return;
    for (all[keep..]) |b| remove(store, id, volume, b.id) catch {};
}

/// Deletes a service's volumes and backups, when the service goes.
pub fn dropAll(store: Store, id: []const u8) void {
    const a = store.a;
    sys.rmrf(std.fmt.allocPrint(a, "{s}/volumes/{s}", .{ store.root, id }) catch return) catch {};
    sys.rmrf(std.fmt.allocPrint(a, "{s}/backups/{s}", .{ store.root, id }) catch return) catch {};
}

const t = std.testing;

test "volume names come from their mount point" {
    try t.expectEqualStrings("data", nameFromMount("/var/lib/postgresql/data"));
    try t.expectEqualStrings("data", nameFromMount("/data/"));
    try t.expect(validMount("/data"));
    try t.expect(!validMount("data"));
    try t.expect(!validMount("/"));
    try t.expect(!validMount("/proc/x"));
    try t.expect(!validMount("/a/../b"));
}

test "backup ids are timestamps" {
    try t.expect(validId("1794271173"));
    try t.expect(!validId("../x"));
    try t.expect(!validId(""));
}
