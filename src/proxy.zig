//! The front door: one event loop that routes HTTP and WebSocket traffic to
//! services by hostname, and logs each request.
//!
//! Anything that can block (starting a container, stopping one) runs in a
//! separate `pharbor` process. It reports back by rewriting routes.json and
//! sending SIGHUP, and requests that arrived meanwhile wait here, parked.

const std = @import("std");
const sys = @import("sys.zig");
const http = @import("http.zig");
const net = @import("net.zig");
const routes = @import("routes.zig");
const engine = @import("engine.zig");
const Store = @import("store.zig").Store;
const linux = sys.linux;
const EPOLL = linux.EPOLL;
const Allocator = std.mem.Allocator;

const ns_per_s = std.time.ns_per_s;
const head_timeout = 20 * ns_per_s;
const connect_timeout = 10 * ns_per_s;
const wake_timeout = 120 * ns_per_s;
const idle_timeout = 300 * ns_per_s;
const drain_timeout = 10 * ns_per_s;
const max_conns = 2048;
const log_max: u64 = 10 * 1024 * 1024;

var reload_requested = std.atomic.Value(bool).init(false);
var stop_requested = std.atomic.Value(bool).init(false);

fn onHup(_: linux.SIG) callconv(.c) void {
    reload_requested.store(true, .monotonic);
}

fn onTerm(_: linux.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}

fn handle(sig: linux.SIG, f: anytype) void {
    var act: linux.Sigaction = .{
        .handler = .{ .handler = f },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(sig, &act, null);
}

/// The phone reached by its IP address, rather than by a service's name.
fn isAddress(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost") or (host.len > 0 and host[0] == '[')) return true;
    for (host) |ch| {
        if (!std.ascii.isDigit(ch) and ch != '.') return false;
    }
    return true;
}

/// The phone's own address and localhost reach the dashboard, even when a
/// default service answers for every other name: otherwise starting a quick
/// tunnel would lock the owner out of the dashboard. A service still gets
/// an address that is one of its own domains.
fn toPanelByAddress(host: []const u8, found: ?*const routes.Route) bool {
    if (!isAddress(host)) return false;
    const r = found orelse return true;
    return std.mem.eql(u8, r.host, "*");
}

/// Must run before the pid file exists: SIGHUP would otherwise be fatal.
pub fn installSignals() void {
    handle(.HUP, onHup);
    handle(.TERM, onTerm);
    handle(.INT, onTerm);
    handle(.PIPE, linux.SIG.IGN);
    // Helpers report back through routes.json, so nobody waits for them.
    handle(.CHLD, linux.SIG.IGN);
}

/// Bytes on their way from one socket to the other.
const Buf = struct {
    mem: []u8 = &.{},
    off: usize = 0,
    len: usize = 0,

    fn data(b: *const Buf) []const u8 {
        return b.mem[b.off..][0..b.len];
    }

    fn free(b: *const Buf) usize {
        return b.mem.len - b.len;
    }

    /// Room to read into, contiguous after any bytes still waiting.
    fn space(b: *Buf) []u8 {
        if (b.off > 0) {
            std.mem.copyForwards(u8, b.mem[0..b.len], b.mem[b.off..][0..b.len]);
            b.off = 0;
        }
        return b.mem[b.len..];
    }

    fn consume(b: *Buf, n: usize) void {
        b.off += n;
        b.len -= n;
        if (b.len == 0) b.off = 0;
    }
};

const State = enum { head, waiting, connecting, relay };

/// Per-service numbers that outlive any one version of the route table.
const Stat = struct {
    active: u32 = 0,
    last_ns: i128,
    /// A helper process is starting or stopping this service.
    busy: bool = false,
};

fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        fn set(self: *@This(), s: []const u8) void {
            self.len = @min(s.len, n);
            @memcpy(self.buf[0..self.len], s[0..self.len]);
        }

        fn get(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

const Conn = struct {
    index: usize = 0,
    client: i32,
    upstream: i32 = -1,
    state: State = .head,
    client_events: u32 = 0,
    upstream_events: u32 = 0,
    head: []u8 = &.{},
    head_len: usize = 0,
    c2u: Buf = .{},
    u2c: Buf = .{},
    c_eof: bool = false,
    u_eof: bool = false,
    u_shut: bool = false,
    upgrade: bool = false,
    retried: bool = false,
    dead: bool = false,
    /// The request was understood, so it belongs in the access log.
    logged: bool = false,
    status: u16 = 0,
    started_ns: i128,
    since_ns: i128,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    stat: ?*Stat = null,
    method: Text(12) = .{},
    path: Text(256) = .{},
    host: Text(256) = .{},
    client_ip: Text(46) = .{},
    service: Text(128) = .{},
};

const LogFile = struct { fd: i32, size: u64 };

pub const Proxy = struct {
    gpa: Allocator,
    a: Allocator,
    store: Store,
    envp: engine.Envp,
    ep: i32 = -1,
    listener: i32 = -1,
    table: routes.Table,
    conns: std.ArrayList(*Conn) = .empty,
    dead: std.ArrayList(*Conn) = .empty,
    stats: std.StringHashMapUnmanaged(*Stat) = .empty,
    logs: std.StringHashMapUnmanaged(LogFile) = .empty,
    last_tick: i128 = 0,

    pub fn run(self: *Proxy, addr: net.Addr) !void {
        self.listener = net.listenTcp(addr) catch |e| {
            if (sys.last == .ADDRINUSE) sys.eprint("error: port {d} is already in use\n", .{addr.port});
            return e;
        };
        self.ep = @intCast(try sys.ck(linux.epoll_create1(linux.EPOLL.CLOEXEC)));
        var ev: linux.epoll_event = .{ .events = EPOLL.IN, .data = .{ .u64 = 0 } };
        _ = try sys.ck(linux.epoll_ctl(self.ep, EPOLL.CTL_ADD, self.listener, &ev));
        self.reload();
        sys.print("listening on {d}.{d}.{d}.{d}:{d}\n", .{ addr.ip[0], addr.ip[1], addr.ip[2], addr.ip[3], addr.port });

        var events: [256]linux.epoll_event = undefined;
        var drain_until: i128 = 0;
        while (true) {
            const n = linux.epoll_wait(self.ep, &events, events.len, 500);
            const count: usize = if (linux.errno(n) == .SUCCESS) n else 0;
            for (events[0..count]) |e| {
                const data = e.data.u64;
                if (data == 0) {
                    self.acceptAll();
                    continue;
                }
                const c: *Conn = @ptrFromInt(data & ~@as(u64, 1));
                if (!c.dead) self.onEvent(c, data & 1 == 1, e.events);
            }
            self.reap();

            if (reload_requested.swap(false, .monotonic)) self.reload();
            const now = sys.monoNs();
            if (stop_requested.load(.monotonic)) {
                if (self.listener >= 0) {
                    sys.close(self.listener);
                    self.listener = -1;
                    drain_until = now + drain_timeout;
                }
                if (self.conns.items.len == 0 or now > drain_until) return;
            }
            if (now - self.last_tick >= ns_per_s) {
                self.last_tick = now;
                self.tick(now);
                self.reap();
            }
        }
    }

    fn statFor(self: *Proxy, name: []const u8) *Stat {
        if (self.stats.get(name)) |s| return s;
        const s = self.gpa.create(Stat) catch @panic("OOM");
        s.* = .{ .last_ns = sys.monoNs() };
        const key = self.gpa.dupe(u8, name) catch @panic("OOM");
        self.stats.put(self.gpa, key, s) catch @panic("OOM");
        return s;
    }

    fn reload(self: *Proxy) void {
        const data = sys.readFileAlloc(self.gpa, self.store.path("routes.json"), 1 << 22) catch "";
        defer if (data.len > 0) self.gpa.free(data);
        if (data.len > 0) {
            if (routes.Table.parse(self.gpa, data)) |t| {
                self.table.deinit();
                self.table = t;
            } else |_| {
                sys.eprint("warning: routes.json could not be read\n", .{});
            }
        }
        // Whatever a helper was doing, it has finished: it is what signalled.
        var it = self.stats.valueIterator();
        while (it.next()) |s| s.*.busy = false;

        var i = self.conns.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.conns.items[i];
            if (c.state != .waiting) continue;
            const r = self.table.lookup(c.host.get()) orelse {
                self.respond(c, 404, "No service answers for this name.");
                continue;
            };
            self.dispatch(c, r);
            if (!c.dead) self.updateInterest(c);
        }
    }

    /// Runs `pharbor <verb> <service>`, reporting back through SIGHUP.
    fn spawnHelper(self: *Proxy, verb: [:0]const u8, service: []const u8) void {
        const name = self.a.dupeSentinel(u8, service, 0) catch return;
        const argv = [_:null]?[*:0]const u8{ "pharbor", verb.ptr, name.ptr };
        const pid = sys.fork() catch return;
        if (pid == 0) {
            handle(.CHLD, linux.SIG.DFL);
            handle(.PIPE, linux.SIG.DFL);
            _ = linux.execve("/proc/self/exe", &argv, self.envp);
            linux.exit_group(127);
        }
    }

    fn acceptAll(self: *Proxy) void {
        while (self.listener >= 0) {
            var sa: linux.sockaddr.in = undefined;
            var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const rc = linux.accept4(self.listener, @ptrCast(&sa), &len, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) return;
            const fd: i32 = @intCast(rc);
            if (self.conns.items.len >= max_conns) {
                sys.close(fd);
                continue;
            }
            self.open(fd, @bitCast(sa.addr)) catch sys.close(fd);
        }
    }

    fn open(self: *Proxy, fd: i32, ip: [4]u8) !void {
        const c = try self.gpa.create(Conn);
        errdefer self.gpa.destroy(c);
        const now = sys.monoNs();
        c.* = .{ .client = fd, .started_ns = now, .since_ns = now };
        var text: [46]u8 = undefined;
        c.client_ip.set(std.fmt.bufPrint(&text, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch "");
        c.head = try self.gpa.alloc(u8, http.max_head);
        errdefer self.gpa.free(c.head);
        c.c2u.mem = try self.gpa.alloc(u8, http.max_head + http.rewrite_margin);
        errdefer self.gpa.free(c.c2u.mem);
        c.u2c.mem = try self.gpa.alloc(u8, http.max_head);
        c.index = self.conns.items.len;
        try self.conns.append(self.gpa, c);
        self.updateInterest(c);
    }

    fn release(self: *Proxy, c: *Conn) void {
        if (c.head.len > 0) self.gpa.free(c.head);
        c.head = &.{};
    }

    fn finish(self: *Proxy, c: *Conn) void {
        if (c.dead) return;
        c.dead = true;
        if (c.logged) self.logRequest(c);
        if (c.stat) |s| {
            s.active -= 1;
            s.last_ns = sys.monoNs();
        }
        sys.close(c.client);
        if (c.upstream >= 0) sys.close(c.upstream);
        self.release(c);
        self.gpa.free(c.c2u.mem);
        self.gpa.free(c.u2c.mem);
        const last = self.conns.pop().?;
        if (last != c) {
            self.conns.items[c.index] = last;
            last.index = c.index;
        }
        self.dead.append(self.gpa, c) catch {};
    }

    /// Events already fetched may still name a closed connection, so it is
    /// freed only after the batch.
    fn reap(self: *Proxy) void {
        for (self.dead.items) |c| self.gpa.destroy(c);
        self.dead.clearRetainingCapacity();
    }

    fn setInterest(self: *Proxy, fd: i32, tag: u64, registered: *u32, want: u32) void {
        if (fd < 0 or registered.* == want) return;
        var ev: linux.epoll_event = .{ .events = want, .data = .{ .u64 = tag } };
        const op: u32 = if (want == 0) EPOLL.CTL_DEL else if (registered.* == 0) EPOLL.CTL_ADD else EPOLL.CTL_MOD;
        _ = linux.epoll_ctl(self.ep, op, fd, &ev);
        registered.* = want;
    }

    /// Stops watching a socket with nothing to do, which also keeps a peer's
    /// hangup from waking the loop while a buffer is full.
    fn updateInterest(self: *Proxy, c: *Conn) void {
        var client_want: u32 = 0;
        var upstream_want: u32 = 0;
        switch (c.state) {
            .head => client_want = EPOLL.IN,
            .waiting => {},
            .connecting => upstream_want = EPOLL.OUT,
            .relay => {
                if (!c.c_eof and c.c2u.free() > 0) client_want |= EPOLL.IN;
                if (c.u2c.len > 0) client_want |= EPOLL.OUT;
                if (!c.u_eof and c.u2c.free() > 0) upstream_want |= EPOLL.IN;
                if (c.c2u.len > 0) upstream_want |= EPOLL.OUT;
            },
        }
        const base: u64 = @intFromPtr(c);
        self.setInterest(c.client, base, &c.client_events, client_want);
        self.setInterest(c.upstream, base | 1, &c.upstream_events, upstream_want);
    }

    fn onEvent(self: *Proxy, c: *Conn, is_upstream: bool, events: u32) void {
        if (!is_upstream and events & (EPOLL.ERR | EPOLL.HUP) != 0) return self.finish(c);
        switch (c.state) {
            .head => self.readHead(c),
            .waiting => {},
            .connecting => if (is_upstream) self.finishConnect(c),
            .relay => self.relay(c),
        }
        if (!c.dead) self.updateInterest(c);
    }

    fn readHead(self: *Proxy, c: *Conn) void {
        const rc = linux.read(c.client, c.head[c.head_len..].ptr, c.head.len - c.head_len);
        const e = linux.errno(rc);
        if (e == .AGAIN or e == .INTR) return;
        if (e != .SUCCESS or rc == 0) return self.finish(c);
        c.head_len += rc;
        const end = http.headEnd(c.head[0..c.head_len]) orelse {
            if (c.head_len == c.head.len) self.respond(c, 431, "The request headers are too large.");
            return;
        };
        self.processHead(c, end);
    }

    fn processHead(self: *Proxy, c: *Conn, end: usize) void {
        const req = http.parseRequest(c.head[0..end]) catch {
            return self.respond(c, 400, "This request could not be understood.");
        };
        var host_buf: [256]u8 = undefined;
        const host = http.normalizeHost(req.host, &host_buf) catch {
            return self.respond(c, 400, "This request could not be understood.");
        };
        c.logged = true;
        c.method.set(req.method);
        c.host.set(host);
        // Webhooks reach the panel through any public hostname.
        const to_panel = std.mem.startsWith(u8, req.target, "/__pharbor/");
        // The query string may hold tokens, and logs get read by more people.
        c.path.set(req.target[0 .. std.mem.indexOfScalar(u8, req.target, '?') orelse req.target.len]);
        c.upgrade = req.upgrade;

        const peer = c.client_ip.get();
        const trusted = std.mem.startsWith(u8, peer, "127.");
        const n = http.rewrite(c.c2u.mem, c.head[0..end], req, peer, trusted) catch {
            return self.respond(c, 431, "The request headers are too large.");
        };
        if (trusted and req.cf_ip.len > 0) {
            c.client_ip.set(req.cf_ip);
        } else if (trusted and req.forwarded_for.len > 0) {
            const first = std.mem.indexOfScalar(u8, req.forwarded_for, ',') orelse req.forwarded_for.len;
            c.client_ip.set(std.mem.trim(u8, req.forwarded_for[0..first], " "));
        }
        c.c2u.len = n;
        const extra = c.head[end..c.head_len];
        @memcpy(c.c2u.mem[n..][0..extra.len], extra);
        c.c2u.len += extra.len;
        c.bytes_in = c.head_len;
        self.release(c);

        if (to_panel and self.table.panel_port != 0) return self.startUpstream(c, self.table.panel_port);
        const found = self.table.lookup(host);
        if (self.table.panel_port != 0 and toPanelByAddress(host, found)) return self.startUpstream(c, self.table.panel_port);
        const r = found orelse return self.respond(c, 404, "No service answers for this name.");
        if (std.mem.eql(u8, r.service, routes.panel_service)) return self.startUpstream(c, r.port);
        c.service.set(r.service);
        const s = self.statFor(r.service);
        s.active += 1;
        s.last_ns = sys.monoNs();
        c.stat = s;
        self.dispatch(c, r);
    }

    /// Sends a request on its way, or parks it until its service is up.
    fn dispatch(self: *Proxy, c: *Conn, r: *const routes.Route) void {
        const s = self.statFor(r.service);
        if (s.busy) return self.park(c);
        if (r.asleep or r.port == 0) {
            self.park(c);
            s.busy = true;
            self.spawnHelper("_wake", r.service);
            return;
        }
        self.startUpstream(c, r.port);
    }

    fn park(_: *Proxy, c: *Conn) void {
        if (c.state != .waiting) c.since_ns = sys.monoNs();
        c.state = .waiting;
    }

    fn startUpstream(self: *Proxy, c: *Conn, port: u16) void {
        const flags = linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC;
        const rc = linux.socket(linux.AF.INET, flags, 0);
        if (linux.errno(rc) != .SUCCESS) return self.respond(c, 502, "The service could not be reached.");
        c.upstream = @intCast(rc);
        c.upstream_events = 0;
        var sa = net.loopback(port);
        const e = linux.errno(linux.connect(c.upstream, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
        c.since_ns = sys.monoNs();
        switch (e) {
            .SUCCESS => {
                c.state = .relay;
                self.relay(c);
            },
            .INPROGRESS => c.state = .connecting,
            else => self.upstreamFailed(c),
        }
    }

    fn finishConnect(self: *Proxy, c: *Conn) void {
        if (net.socketError(c.upstream) != 0) return self.upstreamFailed(c);
        c.state = .relay;
        c.since_ns = sys.monoNs();
        self.relay(c);
    }

    /// The port may be stale if the container came back elsewhere, so check
    /// with the engine once before giving up.
    fn upstreamFailed(self: *Proxy, c: *Conn) void {
        sys.close(c.upstream);
        c.upstream = -1;
        c.upstream_events = 0;
        if (c.retried or c.service.len == 0) return self.respond(c, 502, "The service is not answering.");
        c.retried = true;
        self.park(c);
        const s = self.statFor(c.service.get());
        if (!s.busy) {
            s.busy = true;
            self.spawnHelper("_wake", c.service.get());
        }
    }

    fn respond(self: *Proxy, c: *Conn, status: u16, detail: []const u8) void {
        c.status = status;
        c.state = .relay;
        c.c_eof = true;
        c.u_eof = true;
        c.c2u.len = 0;
        c.c2u.off = 0;
        const body = http.page(c.u2c.mem, status, detail);
        c.u2c.off = 0;
        c.u2c.len = body.len;
        self.relay(c);
        if (!c.dead) self.updateInterest(c);
    }

    fn noteStatus(c: *Conn) void {
        if (c.status != 0) return;
        const code = http.responseStatus(c.u2c.data()) orelse return;
        c.status = code;
    }

    fn relay(self: *Proxy, c: *Conn) void {
        var rounds: u8 = 0;
        var progress = true;
        while (progress and rounds < 16) : (rounds += 1) {
            progress = false;
            if (!c.c_eof and c.c2u.free() > 0) {
                const room = c.c2u.space();
                const rc = linux.read(c.client, room.ptr, room.len);
                const e = linux.errno(rc);
                if (e == .SUCCESS and rc > 0) {
                    c.c2u.len += rc;
                    c.bytes_in += rc;
                    progress = true;
                } else if (e == .SUCCESS) {
                    c.c_eof = true;
                    progress = true;
                } else if (e != .AGAIN and e != .INTR) {
                    return self.finish(c);
                }
            }
            if (c.upstream >= 0 and c.c2u.len > 0) {
                const d = c.c2u.data();
                const rc = linux.write(c.upstream, d.ptr, d.len);
                const e = linux.errno(rc);
                if (e == .SUCCESS) {
                    c.c2u.consume(rc);
                    progress = true;
                } else if (e != .AGAIN and e != .INTR) {
                    // It stopped reading; its response may still be on the way.
                    c.c2u.len = 0;
                    c.c2u.off = 0;
                    c.c_eof = true;
                }
            }
            if (c.upstream >= 0 and c.c_eof and c.c2u.len == 0 and !c.u_shut) {
                c.u_shut = true;
                _ = linux.shutdown(c.upstream, linux.SHUT.WR);
            }
            if (c.upstream >= 0 and !c.u_eof and c.u2c.free() > 0) {
                const room = c.u2c.space();
                const rc = linux.read(c.upstream, room.ptr, room.len);
                const e = linux.errno(rc);
                if (e == .SUCCESS and rc > 0) {
                    c.u2c.len += rc;
                    c.bytes_out += rc;
                    noteStatus(c);
                    progress = true;
                } else if (e == .SUCCESS) {
                    c.u_eof = true;
                    progress = true;
                } else if (e != .AGAIN and e != .INTR) {
                    c.u_eof = true;
                }
            }
            if (c.u2c.len > 0) {
                const d = c.u2c.data();
                const rc = linux.write(c.client, d.ptr, d.len);
                const e = linux.errno(rc);
                if (e == .SUCCESS) {
                    c.u2c.consume(rc);
                    progress = true;
                } else if (e != .AGAIN and e != .INTR) {
                    return self.finish(c);
                }
            }
            if (progress) c.since_ns = sys.monoNs();
        }
        if (c.u_eof and c.u2c.len == 0) return self.finish(c);
        // Stopped early to be fair to the others, with work still to do.
        if (progress and !c.dead) c.since_ns = sys.monoNs();
    }

    fn tick(self: *Proxy, now: i128) void {
        var i = self.conns.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.conns.items[i];
            const age = now - c.since_ns;
            switch (c.state) {
                .head => if (age > head_timeout) self.finish(c),
                .waiting => if (age > wake_timeout) self.respond(c, 503, "The service did not start in time."),
                .connecting => if (age > connect_timeout) self.respond(c, 504, "The service did not answer in time."),
                .relay => if (age > idle_timeout and c.status != 101) self.finish(c),
            }
        }
        self.putIdleToSleep(now);
    }

    fn putIdleToSleep(self: *Proxy, now: i128) void {
        for (self.table.routes) |r| {
            if (r.sleep_after_s == 0 or r.asleep or r.port == 0) continue;
            const s = self.statFor(r.service);
            if (s.busy or s.active > 0) continue;
            if (now - s.last_ns < @as(i128, r.sleep_after_s) * ns_per_s) continue;
            s.busy = true;
            self.spawnHelper("_sleep", r.service);
        }
    }

    fn logFile(self: *Proxy, service: []const u8) ?*LogFile {
        if (self.logs.getPtr(service)) |l| return l;
        const key = self.gpa.dupe(u8, service) catch return null;
        const opened = self.openLog(service) orelse return null;
        self.logs.put(self.gpa, key, opened) catch return null;
        return self.logs.getPtr(service);
    }

    fn logPath(self: *Proxy, service: []const u8, suffix: []const u8) ?sys.Path {
        var p = sys.Path.of(self.store.root) catch return null;
        p.append("/http/") catch return null;
        p.append(service) catch return null;
        p.append(".log") catch return null;
        p.append(suffix) catch return null;
        return p;
    }

    fn openLog(self: *Proxy, service: []const u8) ?LogFile {
        var p = self.logPath(service, "") orelse return null;
        const fd = sys.open(p.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND | sys.O_CLOEXEC, 0o600) catch return null;
        var st: sys.Stat = undefined;
        sys.stat(p.z(), &st) catch {};
        return .{ .fd = fd, .size = @intCast(st.size) };
    }

    fn logRequest(self: *Proxy, c: *Conn) void {
        if (c.service.len == 0) return;
        const service = c.service.get();
        const log = self.logFile(service) orelse return;
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const now_ms: i64 = @intCast(@divFloor(sys.nowNs(), std.time.ns_per_ms));
        const ms: i64 = @intCast(@divFloor(sys.monoNs() - c.started_ns, std.time.ns_per_ms));
        // A request nobody answered: the client left, or the service never did.
        const status: u16 = if (c.status != 0) c.status else 499;
        w.print("{{\"ts\":{d},\"method\":", .{now_ms}) catch return;
        std.json.Stringify.encodeJsonString(c.method.get(), .{}, &w) catch return;
        w.writeAll(",\"host\":") catch return;
        std.json.Stringify.encodeJsonString(c.host.get(), .{}, &w) catch return;
        w.writeAll(",\"path\":") catch return;
        std.json.Stringify.encodeJsonString(c.path.get(), .{}, &w) catch return;
        w.writeAll(",\"client\":") catch return;
        std.json.Stringify.encodeJsonString(c.client_ip.get(), .{}, &w) catch return;
        w.print(",\"status\":{d},\"ms\":{d},\"in\":{d},\"out\":{d}}}\n", .{ status, ms, c.bytes_in, c.bytes_out }) catch return;
        const line = w.buffered();
        sys.writeAll(log.fd, line) catch return;
        log.size += line.len;
        if (log.size > log_max) self.rotate(service, log);
    }

    fn rotate(self: *Proxy, service: []const u8, log: *LogFile) void {
        var cur = self.logPath(service, "") orelse return;
        var old = self.logPath(service, ".1") orelse return;
        sys.close(log.fd);
        sys.rename(cur.z(), old.z()) catch {};
        log.* = self.openLog(service) orelse .{ .fd = -1, .size = 0 };
    }
};

test "an address reaches the dashboard even with a default service" {
    const any: routes.Route = .{ .host = "*", .service = "web", .port = 1 };
    const own: routes.Route = .{ .host = "192.168.1.20", .service = "web", .port = 1 };
    try std.testing.expect(toPanelByAddress("192.168.1.20", null));
    try std.testing.expect(toPanelByAddress("192.168.1.20", &any));
    try std.testing.expect(toPanelByAddress("localhost", &any));
    try std.testing.expect(!toPanelByAddress("192.168.1.20", &own));
    try std.testing.expect(!toPanelByAddress("abc.trycloudflare.com", &any));
}
