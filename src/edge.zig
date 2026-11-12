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
    /// Where domains whose DNS is elsewhere point: pharbor-origin.ZONE.
    origin: []const u8 = "",
    /// The custom hostnames PocketHarbor made, the only ones it removes.
    custom: []const struct { hostname: []const u8, id: []const u8 } = &.{},
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
/// `account_hint` is the account's id, which a token an account owns
/// (cfat_...) needs when it cannot list its account.
pub fn connect(a: Allocator, gpa: Allocator, io: std.Io, key: crypto.Key, store: Store, eng: *engine.Engine, token: []const u8, account_hint: []const u8, failure: *Failure) !State {
    var cf: cloudflare.Client = .{ .gpa = gpa, .io = io, .token = token };
    errdefer failure.message = cf.message;
    const account: []const u8 = if (account_hint.len > 0) account_hint else blk: {
        const accounts = cf.accounts(a) catch |e| {
            if (cloudflare.accountToken(token)) cf.message = "this token belongs to an account: give its Account ID too (on the Cloudflare dashboard's Overview page)";
            return e;
        };
        if (accounts.len == 0) {
            cf.message = if (cloudflare.accountToken(token))
                "this token belongs to an account: give its Account ID too (on the Cloudflare dashboard's Overview page)"
            else
                "the token reaches no account: give it the Cloudflare Tunnel permission";
            return error.CloudflareRefused;
        }
        break :blk accounts[0].id;
    };
    try cf.verify(a, account);
    const id = try store.checkId();
    const name = try std.fmt.allocPrint(a, "pocketharbor-{s}", .{id[0..8]});
    const found = try cf.findTunnel(a, account, name);
    const tun = found orelse try cf.createTunnel(a, account, name);
    {
        const lock = try store.lock();
        defer store.unlock(lock);
        var s = store.settings();
        s.cloudflare_token = try crypto.seal(a, key, token);
        s.cloudflare_account = account;
        s.tunnel_id = tun.id;
        try store.saveSettings(s);
    }
    _ = eng;
    return sync(a, gpa, io, key, store, failure);
}

/// Starts cloudflared for this installation's tunnel. The first time, its
/// image is downloaded: a minute or more on a phone, which is why the
/// dashboard runs this in a process of its own. The marker file says it is
/// under way.
pub fn startConnector(a: Allocator, gpa: Allocator, io: std.Io, key: crypto.Key, store: Store, eng: *engine.Engine, failure: *Failure) !void {
    var cf = try client(a, gpa, io, key, store);
    const s = store.settings();
    const marker = store.path("tunnel-starting");
    var pid_buf: [16]u8 = undefined;
    sys.writeFileAtomic(marker, std.fmt.bufPrint(&pid_buf, "{d}", .{std.os.linux.getpid()}) catch "", 0o600) catch {};
    defer {
        var p = sys.Path.of(marker) catch null;
        if (p) |*m| sys.unlink(m.z()) catch {};
    }
    const run_token = cf.tunnelToken(a, s.cloudflare_account, s.tunnel_id) catch |e| {
        failure.message = cf.message;
        noteError(store, cf.message);
        return e;
    };
    tunnel.named(store, eng, run_token) catch |e| {
        failure.message = "cloudflared did not start; see pharbor tunnel status";
        noteError(store, failure.message);
        return e;
    };
}

/// Whether the connector is downloading or starting right now: the marker
/// names the process doing it, which must still be alive.
pub fn connectorStarting(store: Store) bool {
    const text = sys.readFileAlloc(store.a, store.path("tunnel-starting"), 64) catch return false;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, text, " \n"), 10) catch return false;
    var buf: [32]u8 = undefined;
    const proc = std.fmt.bufPrintSentinel(&buf, "/proc/{d}", .{pid}, 0) catch return false;
    return sys.exists(proc.ptr);
}

fn noteError(store: Store, message: []const u8) void {
    var state = load(store);
    state.@"error" = message;
    save(store, state);
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
    const zones = try cf.zones(a);
    var names: std.ArrayList([]const u8) = .empty;
    for (zones) |z| try names.append(a, z.name);
    state.zones = names.items;

    // Domains of other accounts or providers reach the tunnel through the
    // zone chosen for them, at pharbor-origin.ZONE.
    var saas: ?cloudflare.Zone = null;
    for (zones) |z| {
        if (s.cloudflare_saas_zone.len > 0 and std.ascii.eqlIgnoreCase(z.name, s.cloudflare_saas_zone)) saas = z;
    }
    const public = try publicHosts(a, store);
    var hosts_list: std.ArrayList([]const u8) = .empty;
    try hosts_list.appendSlice(a, public);
    if (saas) |z| {
        state.origin = try std.fmt.allocPrint(a, "{s}.{s}", .{ cloudflare.origin_label, z.name });
        try hosts_list.append(a, state.origin);
    }
    const hosts = hosts_list.items;

    const service = try tunnel.originUrl(store);
    const rules = try a.alloc(cloudflare.Rule, hosts.len);
    for (hosts, 0..) |h, i| rules[i] = .{ .hostname = h, .service = service };
    try cf.setRoutes(a, s.cloudflare_account, s.tunnel_id, rules);

    const target = try std.fmt.allocPrint(a, "{s}.cfargotunnel.com", .{s.tunnel_id});
    var outcomes: std.ArrayList(cloudflare.Outcome) = .empty;
    var foreign: std.ArrayList([]const u8) = .empty;
    for (hosts) |h| {
        if (cloudflare.zoneFor(zones, h) != null) continue;
        if (saas != null) {
            try foreign.append(a, h);
        } else {
            try outcomes.append(a, .{ .host = h, .state = .no_zone, .detail = "no zone of the Cloudflare account holds this name" });
        }
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
    try syncForeign(a, &cf, saas, state.origin, foreign.items, previous, &state, &outcomes);
    state.hosts = outcomes.items;
    save(store, state);
    return state;
}

/// Makes the chosen zone serve each foreign name, and removes the custom
/// hostnames PocketHarbor made for names that are gone.
fn syncForeign(
    a: Allocator,
    cf: *cloudflare.Client,
    saas: ?cloudflare.Zone,
    origin: []const u8,
    foreign: []const []const u8,
    previous: State,
    state: *State,
    outcomes: *std.ArrayList(cloudflare.Outcome),
) !void {
    const Custom = @typeInfo(@TypeOf(state.custom)).pointer.child;
    var kept: std.ArrayList(Custom) = .empty;
    const z = saas orelse {
        // Kept, so that choosing the zone again finds them.
        state.custom = previous.custom;
        return;
    };
    // Without its fallback origin, a zone serves no custom hostname.
    var refused: []const u8 = "";
    cf.setFallbackOrigin(a, z.id, origin) catch {
        refused = try std.fmt.allocPrint(a, "{s}: turn on Cloudflare for SaaS for {s} (SSL/TLS, Custom Hostnames) and give the token SSL and Certificates: Edit", .{ cf.message, z.name });
    };
    const existing: []const cloudflare.CustomHostname = if (refused.len > 0) &.{} else cf.customHostnames(a, z.id) catch blk: {
        refused = cf.message;
        break :blk &.{};
    };
    for (foreign) |h| {
        if (refused.len > 0) {
            try outcomes.append(a, .{ .host = h, .state = .failed, .zone = z.name, .detail = refused });
            continue;
        }
        var found: ?cloudflare.CustomHostname = null;
        for (existing) |ch| {
            if (std.ascii.eqlIgnoreCase(ch.hostname, h)) found = ch;
        }
        const ch = found orelse cf.createCustomHostname(a, z.id, h) catch {
            try outcomes.append(a, .{ .host = h, .state = .failed, .zone = z.name, .detail = cf.message });
            continue;
        };
        try kept.append(a, .{ .hostname = h, .id = ch.id });
        var detail: []const u8 = "";
        if (ch.verification_errors.len > 0) detail = ch.verification_errors[0];
        if (detail.len == 0 and ch.ssl.validation_errors.len > 0) detail = ch.ssl.validation_errors[0].message;
        try outcomes.append(a, .{
            .host = h,
            .state = .foreign,
            .zone = z.name,
            .detail = detail,
            .records = try cloudflare.foreignRecords(a, h, origin, ch),
            .active = ch.active(),
        });
    }
    // Only names PocketHarbor made itself, and that nothing wants any more.
    for (previous.custom) |c| {
        var wanted = false;
        for (foreign) |h| wanted = wanted or std.ascii.eqlIgnoreCase(h, c.hostname);
        if (!wanted) cf.deleteCustomHostname(a, z.id, c.id) catch {};
    }
    state.custom = kept.items;
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
