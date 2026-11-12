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
const relay = @import("relay.zig");
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
    /// Why the relay could not be deployed, if it could not.
    relay_error: []const u8 = "",
    /// The Workers that serve the services' workers.dev names.
    relay_scripts: []const []const u8 = &.{},
};

// The relay ------------------------------------------------------------------

/// A hash of the relay's code: a new version of PocketHarbor uploads it again.
pub fn relayVersion() [16]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(relay.worker_js, &digest, .{});
    return std.fmt.bytesToHex(digest[0..8].*, .lower);
}

/// A name on the account's workers.dev subdomain that PocketHarbor serves.
pub fn isRelayHost(s: store_mod.Settings, host: []const u8) bool {
    if (s.relay_subdomain.len == 0) return false;
    var buf: [128]u8 = undefined;
    const suffix = std.fmt.bufPrint(&buf, ".{s}.workers.dev", .{s.relay_subdomain}) catch return false;
    return host.len > suffix.len and std.ascii.endsWithIgnoreCase(host, suffix);
}

/// "web-02f48b.example.workers.dev" -> "web-02f48b", the Worker's name.
fn relayScript(host: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, host, '.') orelse host.len;
    return host[0..dot];
}

/// The services' Workers that the relay names in use need. The hub serves
/// the dashboard's name but is not one of them: it is never removed or
/// uploaded as a service's.
fn serviceScripts(a: Allocator, hub: []const u8, hosts: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (hosts) |h| {
        const name = relayScript(h);
        if (std.mem.eql(u8, name, hub)) continue;
        try out.append(a, name);
    }
    return out.items;
}

const compatibility_date = "2025-06-01";

fn hubMetadata(a: Allocator, secret: []const u8, migrate: bool) ![]const u8 {
    const Binding = struct { type: []const u8, name: []const u8, class_name: ?[]const u8 = null, text: ?[]const u8 = null };
    const bindings = [_]Binding{
        .{ .type = "durable_object_namespace", .name = "RELAY", .class_name = "Relay" },
        .{ .type = "secret_text", .name = "SECRET", .text = secret },
        .{ .type = "plain_text", .name = "ROLE", .text = "hub" },
    };
    if (migrate) {
        return std.json.Stringify.valueAlloc(a, .{
            .main_module = "relay.js",
            .compatibility_date = compatibility_date,
            .bindings = bindings,
            .migrations = .{ .new_tag = "v1", .new_sqlite_classes = [_][]const u8{"Relay"} },
        }, .{ .emit_null_optional_fields = false });
    }
    return std.json.Stringify.valueAlloc(a, .{ .main_module = "relay.js", .compatibility_date = compatibility_date, .bindings = bindings }, .{ .emit_null_optional_fields = false });
}

fn serviceMetadata(a: Allocator, hub: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .main_module = "relay.js",
        .compatibility_date = compatibility_date,
        .bindings = .{
            .{ .type = "durable_object_namespace", .name = "RELAY", .class_name = "Relay", .script_name = hub },
            .{ .type = "plain_text", .name = "ROLE", .text = "service" },
        },
    }, .{});
}

/// Deploys the relay's hub, unless this version is already there: the
/// Worker and Durable Object the phone connects to. The dashboard gets its
/// address when it has none.
pub fn ensureRelay(a: Allocator, gpa: Allocator, io: std.Io, key: crypto.Key, store: Store, failure: *Failure) !void {
    var cf = try client(a, gpa, io, key, store);
    errdefer failure.message = cf.message;
    const s = store.settings();
    const version = relayVersion();
    if (s.relay_hub.len > 0 and s.relay_url.len > 0 and std.mem.eql(u8, s.relay_version, &version)) return;
    const id = try store.checkId();
    const hub = try std.fmt.allocPrint(a, "pocketharbor-{s}", .{id[0..6]});
    const sub = cf.workersSubdomain(a, s.cloudflare_account) catch try cf.createWorkersSubdomain(a, s.cloudflare_account, hub);
    var secret: []const u8 = "";
    if (s.relay_secret.len > 0) secret = crypto.open(a, key, s.relay_secret) catch "";
    if (secret.len == 0) {
        const raw = try a.alloc(u8, 48);
        sys.randomId(raw);
        secret = raw;
    }
    // The Durable Object's class is declared once; later uploads must not
    // declare it again.
    cf.uploadWorker(a, s.cloudflare_account, hub, try hubMetadata(a, secret, true), relay.worker_js) catch {
        try cf.uploadWorker(a, s.cloudflare_account, hub, try hubMetadata(a, secret, false), relay.worker_js);
    };
    try cf.enableWorkersDev(a, s.cloudflare_account, hub);
    const hub_host = try std.fmt.allocPrint(a, "{s}.{s}.workers.dev", .{ hub, sub });
    {
        const lock = try store.lock();
        defer store.unlock(lock);
        var next = store.settings();
        next.relay_url = try std.fmt.allocPrint(a, "wss://{s}/__harbor/connect", .{hub_host});
        next.relay_secret = try crypto.seal(a, key, secret);
        next.relay_subdomain = sub;
        next.relay_hub = hub;
        next.relay_version = &version;
        if (next.panel_domain.len == 0) next.panel_domain = hub_host;
        try store.saveSettings(next);
    }
    store.syncRoutes();
    // The services' Workers run the same code: they follow it.
    if (s.relay_version.len > 0 and !std.mem.eql(u8, s.relay_version, &version)) {
        for (load(store).relay_scripts) |name| {
            if (std.mem.eql(u8, name, hub)) continue;
            cf.uploadWorker(a, s.cloudflare_account, name, try serviceMetadata(a, hub), relay.worker_js) catch {};
        }
    }
}

/// "ph-" and ten hexadecimal digits: what a service's generated name and
/// relay Worker are called, so that its own name shows nowhere.
fn newUid(a: Allocator) ![]const u8 {
    var hex: [10]u8 = undefined;
    sys.randomId(&hex);
    return std.fmt.allocPrint(a, "ph-{s}", .{&hex});
}

/// The service's uid, made and saved the first time.
fn serviceUid(a: Allocator, store: Store, id: []const u8) ![]const u8 {
    const lock = try store.lock();
    defer store.unlock(lock);
    var svc = try store.load(id);
    if (svc.uid.len > 0) return svc.uid;
    svc.uid = try newUid(a);
    try store.save(svc);
    return svc.uid;
}

/// Gives a service its one generated name: in the zone chosen for them,
/// through the tunnel and with no request limit; otherwise on workers.dev,
/// through the relay. Both are named after the service's uid.
pub fn generateDomain(a: Allocator, gpa: Allocator, io: std.Io, key: crypto.Key, store: Store, id: []const u8, failure: *Failure) ![]const u8 {
    const settings = store.settings();
    {
        const svc = try store.load(id);
        if (svc.generated_domain.len > 0) return error.AlreadyGenerated;
        // Names made before the uid: they count as its generated one.
        for (svc.domains) |d| if (isRelayHost(settings, d)) return error.AlreadyGenerated;
    }
    const uid = try serviceUid(a, store, id);
    var host: []const u8 = undefined;
    if (settings.generated_zone.len > 0) {
        // One level below the zone: Cloudflare's free certificate covers it.
        host = try std.fmt.allocPrint(a, "{s}.{s}", .{ uid, settings.generated_zone });
    } else {
        try ensureRelay(a, gpa, io, key, store, failure);
        var cf = try client(a, gpa, io, key, store);
        errdefer failure.message = cf.message;
        const s = store.settings();
        host = try std.fmt.allocPrint(a, "{s}.{s}.workers.dev", .{ uid, s.relay_subdomain });
        try cf.uploadWorker(a, s.cloudflare_account, uid, try serviceMetadata(a, s.relay_hub), relay.worker_js);
        try cf.enableWorkersDev(a, s.cloudflare_account, uid);
        var state = load(store);
        var names: std.ArrayList([]const u8) = .empty;
        try names.appendSlice(a, state.relay_scripts);
        try names.append(a, uid);
        state.relay_scripts = names.items;
        save(store, state);
    }
    {
        const lock = try store.lock();
        defer store.unlock(lock);
        var current = try store.load(id);
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(a, current.domains);
        try list.append(a, host);
        current.domains = list.items;
        current.generated_domain = host;
        try store.save(current);
    }
    store.syncRoutes();
    return host;
}

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
    var relay_hosts: std.ArrayList([]const u8) = .empty;
    for (public) |h| {
        if (isRelayHost(s, h)) try relay_hosts.append(a, h) else try hosts_list.append(a, h);
    }
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
    // The relay: its hub once, then a Worker per workers.dev name in use.
    if (s.relay_hub.len == 0 or !std.mem.eql(u8, s.relay_version, &relayVersion())) {
        ensureRelay(a, gpa, io, key, store, failure) catch {
            state.relay_error = if (failure.message.len > 0) failure.message else "the relay could not be deployed";
        };
    }
    for (relay_hosts.items) |h| try outcomes.append(a, .{ .host = h, .state = .relay });
    const hub = store.settings().relay_hub;
    const wanted = try serviceScripts(a, hub, relay_hosts.items);
    for (previous.relay_scripts) |name| {
        if (std.mem.eql(u8, name, hub)) continue;
        var keep = false;
        for (wanted) |w| keep = keep or std.mem.eql(u8, w, name);
        if (!keep) cf.deleteWorker(a, s.cloudflare_account, name) catch {};
    }
    state.relay_scripts = wanted;
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
        const s = store.settings();
        for (load(store).relay_scripts) |name| {
            if (!std.mem.eql(u8, name, s.relay_hub)) cf.deleteWorker(a, s.cloudflare_account, name) catch {};
        }
        if (s.relay_hub.len > 0) cf.deleteWorker(a, s.cloudflare_account, s.relay_hub) catch {};
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
    if (isRelayHost(s, s.panel_domain)) s.panel_domain = "";
    s.cloudflare_token = "";
    s.cloudflare_account = "";
    s.relay_url = "";
    s.relay_secret = "";
    s.relay_subdomain = "";
    s.relay_hub = "";
    s.relay_version = "";
    store.saveSettings(s) catch {};
    store.syncRoutes();
    var path = sys.Path.of(store.path("cloudflare.json")) catch return;
    sys.unlink(path.z()) catch {};
}

test "the hub is never one of the services' Workers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try serviceScripts(arena.allocator(), "pocketharbor-02f48b", &.{
        "shop-web-02f48b.abdou-11d.workers.dev",
        "pocketharbor-02f48b.abdou-11d.workers.dev",
        "api-02f48b.abdou-11d.workers.dev",
    });
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("shop-web-02f48b", got[0]);
    try std.testing.expectEqualStrings("api-02f48b", got[1]);
}
