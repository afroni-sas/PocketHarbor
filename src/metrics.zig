//! The history behind the Metrics tab: every 30 seconds, the CPU, memory and
//! process count of each service (from `pdock stats --json`), its HTTP
//! traffic (from the proxy's request log) and the size of its volumes. It
//! runs in the panel's process and keeps about a week per service.
//!
//!   <root>/metrics/<service id>.ndjson   one sample per line, oldest first

const std = @import("std");
const sys = @import("sys.zig");
const engine = @import("engine.zig");
const backup = @import("backup.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Allocator = std.mem.Allocator;
const linux = sys.linux;

pub const interval_s = 30;
/// A week of samples is about 3 MB; past this, the oldest half goes.
const max_bytes = 4 << 20;
/// Walking volumes costs; their size is read every 5 minutes.
const disk_every = 10;
/// Traffic beyond this in one interval is skipped rather than parsed.
const max_http_read = 8 << 20;

pub const Sample = struct {
    /// Unix seconds.
    t: i64,
    /// Percent of one core: 250 is two and a half cores busy.
    cpu: f32 = 0,
    mem: u64 = 0,
    pids: u32 = 0,
    /// Bytes in the service's volumes.
    disk: u64 = 0,
    /// Requests answered during the interval, and how many were 5xx.
    req: u32 = 0,
    err: u32 = 0,
    /// Bytes from clients and to them.
    rx: u64 = 0,
    tx: u64 = 0,
    /// 95th percentile of the response time, in milliseconds.
    p95: u32 = 0,
};

pub fn path(store: Store, id: []const u8) []const u8 {
    return std.fmt.allocPrint(store.a, "{s}/metrics/{s}.ndjson", .{ store.root, id }) catch @panic("OOM");
}

// Sampling -----------------------------------------------------------------

const Cpu = struct { ms: u64, at_ns: i128 };

/// What one tick hands to the next. Each tick builds a fresh copy in its own
/// arena, so containers and services that went away are dropped.
const Memory = struct {
    arena: std.heap.ArenaAllocator,
    cpu: std.StringHashMapUnmanaged(Cpu) = .empty,
    offsets: std.StringHashMapUnmanaged(u64) = .empty,
    disk: std.StringHashMapUnmanaged(u64) = .empty,
};

const Stat = struct { name: []const u8, pids: u32 = 0, memory: u64 = 0, cpu_ms: u64 = 0 };

fn nowS() i64 {
    return @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s));
}

/// Never returns.
pub fn run(root: []const u8, bin: [:0]const u8, envp: engine.Envp) void {
    var memory: Memory = .{ .arena = .init(std.heap.page_allocator) };
    var n: u64 = 0;
    while (true) : (n += 1) {
        const next = tick(root, bin, envp, &memory, n % disk_every == 0);
        memory.arena.deinit();
        memory = next;
        sys.sleepMs(interval_s * 1000);
    }
}

fn tick(root: []const u8, bin: [:0]const u8, envp: engine.Envp, before: *const Memory, measure_disk: bool) Memory {
    var next: Memory = .{ .arena = .init(std.heap.page_allocator) };
    const keep = next.arena.allocator();
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const store: Store = .{ .a = a, .root = root };
    var eng: engine.Engine = .{ .a = a, .bin = bin, .envp = envp };

    var stats: std.StringHashMapUnmanaged(Stat) = .empty;
    if (eng.output(&.{ "stats", "--json" })) |out| {
        var lines = std.mem.tokenizeScalar(u8, out.text, '\n');
        while (lines.next()) |line| {
            const s = std.json.parseFromSliceLeaky(Stat, a, line, .{ .ignore_unknown_fields = true }) catch continue;
            stats.put(a, s.name, s) catch {};
        }
    } else |_| {}

    const services = store.list() catch return next;
    sys.mkdirP(store.path("metrics"), 0o700) catch return next;
    const now = nowS();
    const now_ns = sys.monoNs();
    for (services) |svc| {
        if (svc.deployment == 0) continue;
        const id = store.idOf(svc);
        var sample: Sample = .{ .t = now };

        if (svc.container.len > 0) {
            if (stats.get(svc.container)) |s| {
                sample.mem = s.memory;
                sample.pids = s.pids;
                if (before.cpu.get(svc.container)) |prev| {
                    sample.cpu = @round(cpuPercent(prev, s.cpu_ms, now_ns) * 100) / 100;
                }
                const key = keep.dupe(u8, svc.container) catch continue;
                next.cpu.put(keep, key, .{ .ms = s.cpu_ms, .at_ns = now_ns }) catch {};
            }
        }

        const key = keep.dupe(u8, id) catch continue;
        const log_path = std.fmt.allocPrint(a, "{s}/http/{s}.log", .{ root, id }) catch continue;
        const offset = readTraffic(a, log_path, before.offsets.get(id), &sample);
        next.offsets.put(keep, key, offset) catch {};

        var disk = before.disk.get(id);
        if (measure_disk or disk == null) {
            var total: u64 = 0;
            for (svc.volumes) |v| total += backup.usage(backup.volumeDir(store, id, v.name));
            disk = total;
        }
        sample.disk = disk.?;
        next.disk.put(keep, key, disk.?) catch {};

        append(a, path(store, id), sample);
    }
    return next;
}

fn cpuPercent(prev: Cpu, ms: u64, now_ns: i128) f32 {
    if (ms < prev.ms) return 0; // A new container with the same name.
    const elapsed_ms: f64 = @floatFromInt(@divFloor(now_ns - prev.at_ns, std.time.ns_per_ms));
    if (elapsed_ms <= 0) return 0;
    const used: f64 = @floatFromInt(ms - prev.ms);
    return @floatCast(used * 100.0 / elapsed_ms);
}

/// Adds the requests logged since `offset` to `sample` and returns the new
/// offset. The first time, it starts from the end: history is not traffic
/// of this interval.
fn readTraffic(a: Allocator, log_path: []const u8, offset: ?u64, sample: *Sample) u64 {
    var p = sys.Path.of(log_path) catch return offset orelse 0;
    var st: sys.Stat = undefined;
    sys.stat(p.z(), &st) catch return 0;
    const size: u64 = @intCast(st.size);
    var from = offset orelse return size;
    // The log was rotated: what is in the new file is all new.
    if (size < from) from = 0;
    if (size - from > max_http_read) return size;
    if (size == from) return size;
    const fd = sys.open(p.z(), 0, 0) catch return size;
    defer sys.close(fd);
    const buf = a.alloc(u8, @intCast(size - from)) catch return size;
    const rc = linux.pread(fd, buf.ptr, buf.len, @intCast(from));
    if (linux.errno(rc) != .SUCCESS) return size;
    const data = buf[0..rc];
    // Only whole lines; a line still being written is read next time.
    const end = (std.mem.lastIndexOfScalar(u8, data, '\n') orelse return from) + 1;
    addTraffic(a, data[0..end], sample);
    return from + end;
}

const Request = struct { status: u16 = 0, ms: u32 = 0, in: u64 = 0, out: u64 = 0 };

fn addTraffic(a: Allocator, data: []const u8, sample: *Sample) void {
    var times: std.ArrayList(u32) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const r = std.json.parseFromSliceLeaky(Request, a, line, .{ .ignore_unknown_fields = true }) catch continue;
        sample.req += 1;
        if (r.status >= 500) sample.err += 1;
        sample.rx += r.in;
        sample.tx += r.out;
        times.append(a, r.ms) catch {};
    }
    sample.p95 = percentile(times.items, 95);
}

/// Sorts `values` in place.
fn percentile(values: []u32, p: u32) u32 {
    if (values.len == 0) return 0;
    std.mem.sort(u32, values, {}, std.sort.asc(u32));
    const rank = (values.len * p + 99) / 100;
    return values[@max(rank, 1) - 1];
}

fn append(a: Allocator, file: []const u8, sample: Sample) void {
    const line = std.json.Stringify.valueAlloc(a, sample, .{}) catch return;
    var p = sys.Path.of(file) catch return;
    const fd = sys.open(p.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND, 0o600) catch return;
    sys.writeAll(fd, line) catch {};
    sys.writeAll(fd, "\n") catch {};
    var st: sys.Stat = undefined;
    sys.stat(p.z(), &st) catch {};
    sys.close(fd);
    if (st.size > max_bytes) trim(a, file);
}

/// Keeps the newest half of the file, from a line start.
fn trim(a: Allocator, file: []const u8) void {
    const data = sys.readFileAlloc(a, file, max_bytes * 2) catch return;
    sys.writeFileAtomic(file, newestHalf(data), 0o600) catch {};
}

fn newestHalf(data: []const u8) []const u8 {
    const cut = std.mem.indexOfScalarPos(u8, data, data.len / 2, '\n') orelse return data;
    return data[cut + 1 ..];
}

// Reading ------------------------------------------------------------------

/// One bucket of the chart: averages for CPU, peaks for memory and response
/// time, sums for traffic.
pub const Point = struct {
    t: i64,
    cpu: f32 = 0,
    mem: u64 = 0,
    disk: u64 = 0,
    req: u32 = 0,
    err: u32 = 0,
    rx: u64 = 0,
    tx: u64 = 0,
    p95: u32 = 0,
};

pub const Series = struct { step: i64, from: i64, to: i64, points: []Point };

/// The samples of the last `range_s` seconds before `now`, in at most
/// `max_points` buckets.
pub fn query(a: Allocator, store: Store, id: []const u8, range_s: i64, now: i64, max_points: usize) !Series {
    const data = sys.readFileAlloc(a, path(store, id), max_bytes * 2) catch "";
    return bucket(a, data, range_s, now, max_points);
}

fn stepFor(range_s: i64, max_points: usize) i64 {
    const raw = @divFloor(range_s + @as(i64, @intCast(max_points)) - 1, @as(i64, @intCast(max_points)));
    const steps = @divFloor(raw + interval_s - 1, interval_s);
    return @max(1, steps) * interval_s;
}

fn bucket(a: Allocator, data: []const u8, range_s: i64, now: i64, max_points: usize) !Series {
    const step = stepFor(range_s, max_points);
    const from = @divFloor(now - range_s, step) * step;
    var out: std.ArrayList(Point) = .empty;
    var cpu_sum: f64 = 0;
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        // Old lines are skipped before parsing: a week is 20,000 of them.
        const when = leadingTime(line) orelse continue;
        if (when < from or when > now) continue;
        const s = std.json.parseFromSliceLeaky(Sample, a, line, .{ .ignore_unknown_fields = true }) catch continue;
        const start = @divFloor(s.t, step) * step;
        if (out.items.len == 0 or out.items[out.items.len - 1].t != start) {
            try finish(&out, cpu_sum, count);
            try out.append(a, .{ .t = start });
            cpu_sum = 0;
            count = 0;
        }
        const p = &out.items[out.items.len - 1];
        cpu_sum += s.cpu;
        count += 1;
        p.mem = @max(p.mem, s.mem);
        p.disk = @max(p.disk, s.disk);
        p.req += s.req;
        p.err += s.err;
        p.rx += s.rx;
        p.tx += s.tx;
        p.p95 = @max(p.p95, s.p95);
    }
    try finish(&out, cpu_sum, count);
    return .{ .step = step, .from = from, .to = now, .points = out.items };
}

fn finish(out: *std.ArrayList(Point), cpu_sum: f64, count: u32) !void {
    if (out.items.len == 0 or count == 0) return;
    out.items[out.items.len - 1].cpu = @floatCast(cpu_sum / @as(f64, @floatFromInt(count)));
}

/// `{"t":1794400000,...}`: the time, without parsing the rest.
fn leadingTime(line: []const u8) ?i64 {
    const prefix = "{\"t\":";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    const end = std.mem.indexOfAny(u8, rest, ",}") orelse return null;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch null;
}

const t = std.testing;

test "percentile" {
    var none = [_]u32{};
    try t.expectEqual(@as(u32, 0), percentile(&none, 95));
    var one = [_]u32{7};
    try t.expectEqual(@as(u32, 7), percentile(&one, 95));
    var many: [100]u32 = undefined;
    for (&many, 0..) |*v, i| v.* = @intCast(100 - i);
    try t.expectEqual(@as(u32, 95), percentile(&many, 95));
}

test "traffic from the request log" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var s: Sample = .{ .t = 0 };
    addTraffic(arena.allocator(),
        \\{"ts":1,"method":"GET","host":"a","path":"/","client":"1","status":200,"ms":10,"in":100,"out":1000}
        \\{"ts":2,"method":"GET","host":"a","path":"/x","client":"1","status":502,"ms":30,"in":50,"out":20}
        \\not json
        \\
    , &s);
    try t.expectEqual(@as(u32, 2), s.req);
    try t.expectEqual(@as(u32, 1), s.err);
    try t.expectEqual(@as(u64, 150), s.rx);
    try t.expectEqual(@as(u64, 1020), s.tx);
    try t.expectEqual(@as(u32, 30), s.p95);
}

test "cpu between two samples" {
    const prev: Cpu = .{ .ms = 1000, .at_ns = 0 };
    try t.expectApproxEqAbs(@as(f32, 50), cpuPercent(prev, 1500, std.time.ns_per_s), 0.01);
    try t.expectEqual(@as(f32, 0), cpuPercent(prev, 10, std.time.ns_per_s));
}

test "buckets" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const data =
        \\{"t":900,"cpu":90,"mem":9,"req":9}
        \\{"t":1000,"cpu":10,"mem":100,"req":1,"p95":5}
        \\{"t":1030,"cpu":30,"mem":300,"req":2,"p95":9}
        \\{"t":1060,"cpu":50,"mem":200,"req":3}
        \\{"t":1200,"cpu":70,"mem":50,"req":4}
        \\
    ;
    // 4 points over 240 s: buckets of 60 s, the sample at 900 is too old.
    const s = try bucket(arena.allocator(), data, 240, 1200, 4);
    try t.expectEqual(@as(i64, 60), s.step);
    try t.expectEqual(@as(usize, 3), s.points.len);
    try t.expectEqual(@as(i64, 960), s.points[0].t);
    try t.expectApproxEqAbs(@as(f32, 10), s.points[0].cpu, 0.01);
    try t.expectEqual(@as(i64, 1020), s.points[1].t);
    try t.expectApproxEqAbs(@as(f32, 40), s.points[1].cpu, 0.01);
    try t.expectEqual(@as(u64, 300), s.points[1].mem);
    try t.expectEqual(@as(u32, 5), s.points[1].req);
    try t.expectEqual(@as(u32, 9), s.points[1].p95);
    try t.expectEqual(@as(i64, 1200), s.points[2].t);
}

test "the step is a whole number of intervals" {
    try t.expectEqual(@as(i64, 30), stepFor(3600, 240));
    try t.expectEqual(@as(i64, 90), stepFor(6 * 3600, 240));
    try t.expectEqual(@as(i64, 2520), stepFor(7 * 86400, 240));
}

test "trimming keeps whole lines" {
    try t.expectEqualStrings("d\n", newestHalf("a\nb\nc\nd\n"));
    try t.expectEqualStrings("x", newestHalf("x"));
}
