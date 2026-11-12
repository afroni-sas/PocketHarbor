//! Public access through the user's Cloudflare account: connecting it,
//! then keeping its tunnel routes and DNS records in step with the public
//! names of the services. Each sync writes what it found to cloudflare.json,
//! which the dashboard reads without calling Cloudflare.

const std = @import("std");
const sys = @import("sys.zig");
const crypto = @import("crypto.zig");
const cloudflare = @import("cloudflare.zig");
const tunnel = @import("tunnel.zig");
const store_mod = @import("store.zig");
const engine = @import("engine.zig");
const Store = store_mod.Store;
const Allocator = std.mem.Allocator;

pub const State = struct {
    synced_at: i64 = 0,
    /// Why the last sync stopped, in Cloudflare's words.
    @"error": []const u8 = "",
    account: []const u8 = "",
    /// Every zone of the account, for the names a domain can use.
    zones: []const []const u8 = &.{},
    hosts: []const cloudflare.Outcome = &.{},
};

pub fn load(store: Store) State {
    const data = sys.readFileAlloc(store.a, store.path("cloudflare.json"), 1 << 20) catch return .{};
    return std.json.parseFromSliceLeaky(State, store.a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
}

fn save(store: Store, state: State) void {
    const data = std.json.Stringify.valueAlloc(store.a, state, .{}) catch return;
    sys.writeFileAtomic(store.path("cloudflare.json"), data, 0o600) catch {};
}

pub fn connected(store: Store) bool {
    const s = store.settings();
    return s.cloudflare_token.len > 0 and s.cloudflare_account.len > 0 and s.tunnel_id.len > 0;
}

/// The outcome of the last sync for `host`.
pub fn outcomeOf(state: State, host: []const u8) ?cloudflare.Outcome {
    for (state.hosts) |h| if (std.ascii.eqlIgnoreCase(h.host, host)) return h;
    return null;
}

/// The names to route: custom domains and the dashboard's first, then one
/// wildcard for the base domain, which Cloudflare matches last.
pub fn publicHosts(a: Allocator, store: Store) ![]const []const u8 {
    const s = store.settings();
    var out: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn f(list: *std.ArrayList([]const u8), al: Allocator, host: []const u8) !void {
            for (list.items) |h| if (std.ascii.eqlIgnoreCase(h, host)) return;
            try list.append(al, host);
        }
    }.f;
    for (try store.list()) |svc| {
        for (svc.domains) |d| if (!std.mem.eql(u8, d, "*")) try add(&out, a, d);
    }
    if (s.panel_domain.len > 0) try add(&out, a, s.panel_domain);
    if (s.base_domain.len > 0) try add(&out, a, try std.fmt.allocPrint(a, "*.{s}", .{s.base_domain}));
    return out.items;
}

fn client(a: Allocator, gpa: Allocator, io: std.Io, key: crypto.Key, store: Store) !cloudflare.Client {
    const sealed = store.settings().cloudflare_token;
    if (sealed.len == 0) return error.NotConnected;
    return .{ .gpa = gpa, .io = io, .token = try crypto.open(a, key, sealed) };
}

pub const Failure = struct { err: anyerror, message: []const u8 };

/// Checks the token, creates this installation's tunnel in the account (or
/// finds it again), starts it, and syncs. On failure nothing is saved.
pub fn connect(a: Allocator, gpa: Allocator, io: std.Io, key: crypto.Key, store: Store, eng: *engine.Engine, token: []const u8, failure: *Failure) !State {
    var cf: cloudflare.Client = .{ .gpa = gpa, .io = io, .token = token };
    errdefer failure.message = cf.message;
    try cf.verify(a);
    const accounts = try cf.accounts(a);
    if (accounts.len == 0) {
        cf.message = "the token reaches no account: give it the Cloudflare Tunnel permission";
        return error.CloudflareRefused;
    }
    const account = accounts[0].id;
    const id = try store.checkId();
    const name = try std.fmt.allocPrint(a, "pocketharbor-{s}", .{id[0..8]});
    const found = try cf.findTunnel(a, account, name);
    const tun = found orelse try cf.createTunnel(a, account, name);
    const run_token = try cf.tunnelToken(a, account, tun.id);
    {
        const lock = try store.lock();
        defer store.unlock(lock);
        var s = store.settings();
        s.cloudflare_token = try crypto.seal(a, key, token);
        s.cloudflare_account = account;
        try store.saveSettings(s);
    }
    tunnel.named(store, eng, run_token) catch {
        cf.message = "the tunnel was created but cloudflared did not start; see pharbor tunnel status";
        return error.TunnelFailed;
    };
    return sync(a, gpa, io, key, store, failure);
}

/// Points every public name at the tunnel: its routes first, then a DNS
/// record for each name in a zone of the account. Records that hold a name
/// already are left alone and reported; records PocketHarbor wrote for names
/// that are gone are removed.
pub fn sync(a: Allocator, gpa: Allocator, io: std.Io, key: crypto.Key, store: Store, failure: *Failure) !State {
    var cf = try client(a, gpa, io, key, store);
    const s = store.settings();
    var state: State = .{ .synced_at = @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s)), .account = s.cloudflare_account };
    errdefer {
        failure.message = cf.message;
        state.@"error" = cf.message;
        save(store, state);
    }
    const hosts = try publicHosts(a, store);
    const origin = try tunnel.originUrl(store);
    const rules = try a.alloc(cloudflare.Rule, hosts.len);
    for (hosts, 0..) |h, i| rules[i] = .{ .hostname = h, .service = origin };
    try cf.setRoutes(a, s.cloudflare_account, s.tunnel_id, rules);

    const zones = try cf.zones(a);
    var names: std.ArrayList([]const u8) = .empty;
    for (zones) |z| try names.append(a, z.name);
    state.zones = names.items;
    const target = try std.fmt.allocPrint(a, "{s}.cfargotunnel.com", .{s.tunnel_id});
    var outcomes: std.ArrayList(cloudflare.Outcome) = .empty;
    for (hosts) |h| {
        if (cloudflare.zoneFor(zones, h) == null) try outcomes.append(a, .{ .host = h, .state = .no_zone, .detail = "no zone of the Cloudflare account holds this name" });
    }
    // Zones with a name to write, and those that may hold records to remove.
    const previous = load(store);
    for (zones) |z| {
        var mine: std.ArrayList([]const u8) = .empty;
        for (hosts) |h| {
            const owner = cloudflare.zoneFor(zones, h) orelse continue;
            if (std.mem.eql(u8, owner.id, z.id)) try mine.append(a, h);
        }
        var had = false;
        for (previous.hosts) |o| had = had or std.ascii.eqlIgnoreCase(o.zone, z.name);
        if (mine.items.len == 0 and !had) continue;
        const existing = try cf.records(a, z.id);
        const p = try cloudflare.plan(a, existing, mine.items, target);
        for (mine.items) |h| {
            var done = false;
            for (p.conflicts) |r| {
                if (!std.ascii.eqlIgnoreCase(r.name, h)) continue;
                try outcomes.append(a, .{ .host = h, .state = .conflict, .zone = z.name, .detail = try std.fmt.allocPrint(a, "a {s} record already points this name to {s}", .{ r.type, r.content }) });
                done = true;
            }
            for (p.create) |c| {
                if (done or !std.ascii.eqlIgnoreCase(c, h)) continue;
                done = true;
                _ = cf.createRecord(a, z.id, try cloudflare.tunnelRecord(a, h, s.tunnel_id)) catch {
                    try outcomes.append(a, .{ .host = h, .state = .failed, .zone = z.name, .detail = cf.message });
                    continue;
                };
                try outcomes.append(a, .{ .host = h, .state = .ready, .zone = z.name });
            }
            if (!done) try outcomes.append(a, .{ .host = h, .state = .ready, .zone = z.name });
        }
        for (p.remove) |r| cf.deleteRecord(a, z.id, r.id) catch {};
    }
    state.hosts = outcomes.items;
    save(store, state);
    return state;
}

/// Removes the records PocketHarbor wrote, stops the tunnel and forgets the
/// token. The tunnel stays in the account, ready for the next connection.
pub fn disconnect(a: Allocator, gpa: Allocator, io: std.Io, key: crypto.Key, store: Store, eng: *engine.Engine) void {
    if (client(a, gpa, io, key, store)) |c| {
        var cf = c;
        const zones = cf.zones(a) catch &.{};
        for (zones) |z| {
            const existing = cf.records(a, z.id) catch continue;
            const p = cloudflare.plan(a, existing, &.{}, "") catch continue;
            for (p.remove) |r| cf.deleteRecord(a, z.id, r.id) catch {};
        }
    } else |_| {}
    tunnel.stop(store, eng);
    const lock = store.lock() catch return;
    defer store.unlock(lock);
    var s = store.settings();
    s.cloudflare_token = "";
    s.cloudflare_account = "";
    store.saveSettings(s) catch {};
    var path = sys.Path.of(store.path("cloudflare.json")) catch return;
    sys.unlink(path.z()) catch {};
}
