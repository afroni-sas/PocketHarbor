//! Real DNS through Cloudflare's API, the way Railway hands out working
//! domains: with an API token, PocketHarbor creates its own tunnel, routes
//! every public name of the services through it, and writes their DNS
//! records in the account's zones. Records it made carry a comment, so that
//! it only ever removes its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const api_root = "https://api.cloudflare.com/client/v4";

/// The comment on every DNS record PocketHarbor writes.
pub const record_comment = "Managed by PocketHarbor";

/// A token made with these permissions is all it takes. Workers Scripts is
/// for the relay and its workers.dev addresses; SSL and Certificates for
/// domains whose DNS is elsewhere (Cloudflare for SaaS).
pub const token_permissions = "Account: Workers Scripts: Edit, Account: Cloudflare Tunnel: Edit, Zone: DNS: Edit, Zone: Zone: Read, Zone: SSL and Certificates: Edit";

/// The name, in the zone chosen for them, that domains whose DNS is
/// elsewhere point at: Cloudflare's "fallback origin".
pub const origin_label = "pharbor-origin";

pub const Account = struct { id: []const u8, name: []const u8 = "" };
pub const Zone = struct { id: []const u8, name: []const u8, status: []const u8 = "", account: struct { id: []const u8 = "" } = .{} };
pub const Tunnel = struct { id: []const u8, name: []const u8 = "", deleted_at: ?[]const u8 = null };
pub const DnsRecord = struct {
    id: []const u8 = "",
    type: []const u8,
    name: []const u8,
    content: []const u8,
    proxied: bool = false,
    comment: ?[]const u8 = null,
};
pub const Rule = struct { hostname: ?[]const u8 = null, service: []const u8 };

/// A name of someone else's DNS that a zone of this account serves
/// (Cloudflare for SaaS).
pub const CustomHostname = struct {
    id: []const u8 = "",
    hostname: []const u8 = "",
    /// "active" once Cloudflare saw the name point here.
    status: []const u8 = "",
    ssl: struct {
        status: []const u8 = "",
        validation_errors: []const struct { message: []const u8 = "" } = &.{},
    } = .{},
    ownership_verification: struct { name: []const u8 = "", type: []const u8 = "", value: []const u8 = "" } = .{},
    verification_errors: []const []const u8 = &.{},

    pub fn active(self: CustomHostname) bool {
        return std.mem.eql(u8, self.status, "active") and std.mem.eql(u8, self.ssl.status, "active");
    }
};

pub const Error = error{
    /// The token is wrong, expired or lacks a permission; `Client.message` says which.
    CloudflareRefused,
    CloudflareUnreachable,
    CloudflareError,
};

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    token: []const u8,
    api: []const u8 = api_root,
    /// Cloudflare's own words about the last failure.
    message: []const u8 = "",

    /// Calls the API and returns the envelope's `result`, parsed as T.
    fn call(self: *Client, a: Allocator, comptime T: type, method: std.http.Method, path: []const u8, body: ?[]const u8) !T {
        return self.callTyped(a, T, method, path, body, "application/json");
    }

    fn callTyped(self: *Client, a: Allocator, comptime T: type, method: std.http.Method, path: []const u8, body: ?[]const u8, content_type: []const u8) !T {
        var http: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer http.deinit();
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ self.api, path });
        const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{self.token});
        var req = http.request(method, std.Uri.parse(url) catch return error.CloudflareError, .{
            .keep_alive = false,
            .redirect_behavior = .not_allowed,
            .headers = .{
                .accept_encoding = .omit,
                .user_agent = .{ .override = "pocketharbor" },
                .authorization = .{ .override = auth },
                .content_type = if (body != null) .{ .override = content_type } else .default,
            },
        }) catch return self.unreachable_("Cloudflare could not be reached");
        defer req.deinit();
        if (body) |b| {
            req.sendBodyComplete(@constCast(b)) catch return self.unreachable_("the request to Cloudflare failed");
        } else {
            req.sendBodiless() catch return self.unreachable_("the request to Cloudflare failed");
        }
        var head_buf: [16384]u8 = undefined;
        var resp = req.receiveHead(&head_buf) catch return self.unreachable_("Cloudflare did not answer");
        var transfer: [16384]u8 = undefined;
        const rd = resp.reader(&transfer);
        var text: std.ArrayList(u8) = .empty;
        var buf: [16384]u8 = undefined;
        while (text.items.len < 8 << 20) {
            const n = rd.readSliceShort(&buf) catch return self.unreachable_("Cloudflare's answer was cut");
            if (n == 0) break;
            try text.appendSlice(a, buf[0..n]);
        }
        const Envelope = struct {
            success: bool = false,
            errors: []const struct {
                code: i64 = 0,
                message: []const u8 = "",
                error_chain: []const struct { message: []const u8 = "" } = &.{},
            } = &.{},
            result: ?T = null,
        };
        const env = std.json.parseFromSliceLeaky(Envelope, a, text.items, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            self.message = try std.fmt.allocPrint(a, "Cloudflare answered {d} with something unreadable", .{@intFromEnum(resp.head.status)});
            return error.CloudflareError;
        };
        if (!env.success) {
            self.message = "Cloudflare refused the request";
            if (env.errors.len > 0) {
                const e = env.errors[0];
                self.message = if (e.error_chain.len > 0)
                    try std.fmt.allocPrint(a, "{s}: {s}", .{ e.message, e.error_chain[0].message })
                else
                    e.message;
            }
            const code = @intFromEnum(resp.head.status);
            return if (code == 400 or code == 401 or code == 403) error.CloudflareRefused else error.CloudflareError;
        }
        return env.result orelse error.CloudflareError;
    }

    fn unreachable_(self: *Client, why: []const u8) Error {
        self.message = why;
        return error.CloudflareUnreachable;
    }

    /// A user token is checked at /user/tokens; one an account owns
    /// (cfat_...) only at its account's /tokens.
    pub fn verify(self: *Client, a: Allocator, account: ?[]const u8) !void {
        const Status = struct { status: []const u8 = "" };
        if (account) |id| {
            if (accountToken(self.token)) {
                const path = try std.fmt.allocPrint(a, "/accounts/{s}/tokens/verify", .{id});
                _ = try self.call(a, Status, .GET, path, null);
                return;
            }
        }
        _ = self.call(a, Status, .GET, "/user/tokens/verify", null) catch |e| {
            const id = account orelse return e;
            const path = try std.fmt.allocPrint(a, "/accounts/{s}/tokens/verify", .{id});
            _ = try self.call(a, Status, .GET, path, null);
        };
    }

    pub fn accounts(self: *Client, a: Allocator) ![]const Account {
        return self.call(a, []const Account, .GET, "/accounts?per_page=50", null);
    }

    /// The zones the token can edit, active or still waiting for their
    /// nameservers.
    pub fn zones(self: *Client, a: Allocator) ![]const Zone {
        return self.call(a, []const Zone, .GET, "/zones?per_page=50", null);
    }

    pub fn findTunnel(self: *Client, a: Allocator, account: []const u8, name: []const u8) !?Tunnel {
        const path = try std.fmt.allocPrint(a, "/accounts/{s}/cfd_tunnel?is_deleted=false&name={s}", .{ account, name });
        const list = try self.call(a, []const Tunnel, .GET, path, null);
        for (list) |tun| if (tun.deleted_at == null and std.mem.eql(u8, tun.name, name)) return tun;
        return null;
    }

    /// A tunnel whose routes live at Cloudflare, so that they can be set here.
    pub fn createTunnel(self: *Client, a: Allocator, account: []const u8, name: []const u8) !Tunnel {
        const path = try std.fmt.allocPrint(a, "/accounts/{s}/cfd_tunnel", .{account});
        const body = try std.json.Stringify.valueAlloc(a, .{ .name = name, .config_src = "cloudflare" }, .{});
        return self.call(a, Tunnel, .POST, path, body);
    }

    /// What cloudflared runs with.
    pub fn tunnelToken(self: *Client, a: Allocator, account: []const u8, id: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(a, "/accounts/{s}/cfd_tunnel/{s}/token", .{ account, id });
        return self.call(a, []const u8, .GET, path, null);
    }

    /// Replaces the tunnel's routes: each rule's hostname to its service,
    /// and a 404 for anything else, which Cloudflare requires last.
    pub fn setRoutes(self: *Client, a: Allocator, account: []const u8, id: []const u8, rules: []const Rule) !void {
        const path = try std.fmt.allocPrint(a, "/accounts/{s}/cfd_tunnel/{s}/configurations", .{ account, id });
        const body = try routesBody(a, rules);
        _ = try self.call(a, std.json.Value, .PUT, path, body);
    }

    pub fn records(self: *Client, a: Allocator, zone: []const u8) ![]const DnsRecord {
        const path = try std.fmt.allocPrint(a, "/zones/{s}/dns_records?per_page=5000", .{zone});
        return self.call(a, []const DnsRecord, .GET, path, null);
    }

    pub fn createRecord(self: *Client, a: Allocator, zone: []const u8, rec: DnsRecord) !DnsRecord {
        const path = try std.fmt.allocPrint(a, "/zones/{s}/dns_records", .{zone});
        const body = try std.json.Stringify.valueAlloc(a, .{
            .type = rec.type,
            .name = rec.name,
            .content = rec.content,
            .proxied = rec.proxied,
            .ttl = 1,
            .comment = record_comment,
        }, .{});
        return self.call(a, DnsRecord, .POST, path, body);
    }

    /// Where Cloudflare sends the custom hostnames of a zone.
    pub fn setFallbackOrigin(self: *Client, a: Allocator, zone: []const u8, origin: []const u8) !void {
        const path = try std.fmt.allocPrint(a, "/zones/{s}/custom_hostnames/fallback_origin", .{zone});
        const body = try std.json.Stringify.valueAlloc(a, .{ .origin = origin }, .{});
        _ = try self.call(a, std.json.Value, .PUT, path, body);
    }

    pub fn customHostnames(self: *Client, a: Allocator, zone: []const u8) ![]const CustomHostname {
        const path = try std.fmt.allocPrint(a, "/zones/{s}/custom_hostnames?per_page=50", .{zone});
        return self.call(a, []const CustomHostname, .GET, path, null);
    }

    /// The certificate is validated over HTTP, which renews by itself once
    /// the name's CNAME points here.
    pub fn createCustomHostname(self: *Client, a: Allocator, zone: []const u8, hostname: []const u8) !CustomHostname {
        const path = try std.fmt.allocPrint(a, "/zones/{s}/custom_hostnames", .{zone});
        const body = try std.json.Stringify.valueAlloc(a, .{ .hostname = hostname, .ssl = .{ .method = "http", .type = "dv" } }, .{});
        return self.call(a, CustomHostname, .POST, path, body);
    }

    pub fn deleteCustomHostname(self: *Client, a: Allocator, zone: []const u8, id: []const u8) !void {
        const path = try std.fmt.allocPrint(a, "/zones/{s}/custom_hostnames/{s}", .{ zone, id });
        _ = try self.call(a, std.json.Value, .DELETE, path, null);
    }

    /// The account's name under workers.dev, chosen once per account.
    pub fn workersSubdomain(self: *Client, a: Allocator, account: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(a, "/accounts/{s}/workers/subdomain", .{account});
        const got = try self.call(a, struct { subdomain: []const u8 = "" }, .GET, path, null);
        if (got.subdomain.len == 0) return error.CloudflareError;
        return got.subdomain;
    }

    /// The names of the account's Workers.
    pub fn workerNames(self: *Client, a: Allocator, account: []const u8) ![]const []const u8 {
        const path = try std.fmt.allocPrint(a, "/accounts/{s}/workers/scripts", .{account});
        const list = try self.call(a, []const struct { id: []const u8 = "" }, .GET, path, null);
        const out = try a.alloc([]const u8, list.len);
        for (list, 0..) |w, i| out[i] = w.id;
        return out;
    }

    /// Only for an account that has no workers.dev subdomain yet: on one
    /// that has, this would rename it, and every workers.dev address of the
    /// account with it.
    pub fn createWorkersSubdomain(self: *Client, a: Allocator, account: []const u8, name: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(a, "/accounts/{s}/workers/subdomain", .{account});
        const body = try std.json.Stringify.valueAlloc(a, .{ .subdomain = name }, .{});
        const got = try self.call(a, struct { subdomain: []const u8 = "" }, .PUT, path, body);
        return got.subdomain;
    }

    /// Uploads a Worker: `metadata` is its JSON description, `code` its
    /// single module, relay.js.
    pub fn uploadWorker(self: *Client, a: Allocator, account: []const u8, name: []const u8, metadata: []const u8, code: []const u8) !void {
        const path = try std.fmt.allocPrint(a, "/accounts/{s}/workers/scripts/{s}", .{ account, name });
        const boundary = "pocketharbor-relay-boundary-7f3a9c";
        const body = try std.fmt.allocPrint(a, "--{s}\r\nContent-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\nContent-Type: application/json\r\n\r\n{s}\r\n" ++
            "--{s}\r\nContent-Disposition: form-data; name=\"relay.js\"; filename=\"relay.js\"\r\nContent-Type: application/javascript+module\r\n\r\n{s}\r\n--{s}--\r\n", .{ boundary, metadata, boundary, code, boundary });
        _ = try self.callTyped(a, std.json.Value, .PUT, path, body, "multipart/form-data; boundary=" ++ boundary);
    }

    /// Puts a Worker on NAME.SUBDOMAIN.workers.dev.
    pub fn enableWorkersDev(self: *Client, a: Allocator, account: []const u8, name: []const u8) !void {
        const path = try std.fmt.allocPrint(a, "/accounts/{s}/workers/scripts/{s}/subdomain", .{ account, name });
        _ = try self.call(a, std.json.Value, .POST, path, "{\"enabled\":true,\"previews_enabled\":false}");
    }

    pub fn deleteWorker(self: *Client, a: Allocator, account: []const u8, name: []const u8) !void {
        const path = try std.fmt.allocPrint(a, "/accounts/{s}/workers/scripts/{s}?force=true", .{ account, name });
        _ = try self.call(a, std.json.Value, .DELETE, path, null);
    }

    pub fn deleteRecord(self: *Client, a: Allocator, zone: []const u8, id: []const u8) !void {
        const path = try std.fmt.allocPrint(a, "/zones/{s}/dns_records/{s}", .{ zone, id });
        _ = try self.call(a, std.json.Value, .DELETE, path, null);
    }
};

/// Whether Cloudflare's message says the account has no workers.dev
/// subdomain, as opposed to any other failure to read it.
pub fn noSubdomain(message: []const u8) bool {
    return std.ascii.findIgnoreCase(message, "not found") != null or
        std.ascii.findIgnoreCase(message, "not_found") != null or
        std.ascii.findIgnoreCase(message, "does not have") != null;
}

/// Tokens an account owns start with cfat_; a user's with cfut_, or nothing
/// for the older ones.
pub fn accountToken(token: []const u8) bool {
    return std.mem.startsWith(u8, token, "cfat_");
}

/// An account id: 32 hexadecimal digits.
pub fn validAccount(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn routesBody(a: Allocator, rules: []const Rule) ![]const u8 {
    var all: std.ArrayList(Rule) = .empty;
    try all.appendSlice(a, rules);
    try all.append(a, .{ .service = "http_status:404" });
    return std.json.Stringify.valueAlloc(a, .{ .config = .{ .ingress = all.items } }, .{ .emit_null_optional_fields = false });
}

/// The zone of the account that holds `host`: the longest name it ends with.
pub fn zoneFor(list: []const Zone, host: []const u8) ?Zone {
    const name = if (std.mem.startsWith(u8, host, "*.")) host[2..] else host;
    var best: ?Zone = null;
    for (list) |z| {
        const inside = std.ascii.eqlIgnoreCase(name, z.name) or
            (name.len > z.name.len and std.ascii.endsWithIgnoreCase(name, z.name) and name[name.len - z.name.len - 1] == '.');
        if (inside and (best == null or z.name.len > best.?.name.len)) best = z;
    }
    return best;
}

/// Cloudflare's free certificate covers a zone and one level below it:
/// `app.example.com`, not `x.app.example.com`.
pub fn certificateCovers(zone: []const u8, host: []const u8) bool {
    const name = if (std.mem.startsWith(u8, host, "*.")) host[2..] else host;
    if (std.ascii.eqlIgnoreCase(name, zone)) return true;
    if (name.len <= zone.len + 1) return false;
    const below = name[0 .. name.len - zone.len - 1];
    // A wildcard covers one level of its own: *.example.com is fine.
    if (std.mem.startsWith(u8, host, "*.")) return false;
    return std.mem.indexOfScalar(u8, below, '.') == null;
}

/// What a name's DNS is like, before or after a sync.
pub const RecordState = enum {
    /// A name on workers.dev, served by PocketHarbor's relay: no DNS to write.
    relay,
    /// Its DNS is elsewhere: the records in `Outcome.records` go there, and
    /// a zone of the account serves it (Cloudflare for SaaS).
    foreign,
    /// PocketHarbor wrote it, or it already pointed at the tunnel.
    ready,
    /// Another record holds the name; PocketHarbor leaves it alone.
    conflict,
    /// No zone of the account holds the name.
    no_zone,
    /// Cloudflare refused to write it.
    failed,
};

pub const Outcome = struct {
    host: []const u8,
    state: RecordState,
    zone: []const u8 = "",
    detail: []const u8 = "",
    /// For a foreign name: the records to add where its DNS is.
    records: []const DnsRecord = &.{},
    /// For a foreign name: whether Cloudflare serves it yet.
    active: bool = false,
};

/// What the owner of a foreign name adds to its DNS: a CNAME to the fallback
/// origin, and the TXT record that proves the name is theirs.
pub fn foreignRecords(a: Allocator, host: []const u8, origin: []const u8, ch: CustomHostname) ![]const DnsRecord {
    var out: std.ArrayList(DnsRecord) = .empty;
    try out.append(a, .{ .type = "CNAME", .name = host, .content = origin });
    if (ch.ownership_verification.name.len > 0) {
        try out.append(a, .{ .type = "TXT", .name = ch.ownership_verification.name, .content = ch.ownership_verification.value });
    }
    return out.items;
}

/// The CNAME record that sends `host` into tunnel `id`.
pub fn tunnelRecord(a: Allocator, host: []const u8, id: []const u8) !DnsRecord {
    return .{ .type = "CNAME", .name = host, .content = try std.fmt.allocPrint(a, "{s}.cfargotunnel.com", .{id}), .proxied = true };
}

/// Decides what to do with a zone's records: which of `hosts` need a record
/// and which records PocketHarbor wrote that nothing needs any more.
pub fn plan(a: Allocator, existing: []const DnsRecord, hosts: []const []const u8, target: []const u8) !struct {
    create: []const []const u8,
    remove: []const DnsRecord,
    conflicts: []const DnsRecord,
} {
    var create: std.ArrayList([]const u8) = .empty;
    var remove: std.ArrayList(DnsRecord) = .empty;
    var conflicts: std.ArrayList(DnsRecord) = .empty;
    for (hosts) |h| {
        var found: ?DnsRecord = null;
        for (existing) |r| {
            if (std.ascii.eqlIgnoreCase(r.name, h) and !std.mem.eql(u8, r.type, "TXT") and !std.mem.eql(u8, r.type, "MX")) found = r;
        }
        if (found) |r| {
            if (!std.ascii.eqlIgnoreCase(r.content, target)) try conflicts.append(a, r);
        } else {
            try create.append(a, h);
        }
    }
    for (existing) |r| {
        const ours = r.comment != null and std.mem.eql(u8, r.comment.?, record_comment);
        if (!ours) continue;
        var wanted = false;
        for (hosts) |h| wanted = wanted or std.ascii.eqlIgnoreCase(r.name, h);
        if (!wanted) try remove.append(a, r);
    }
    return .{ .create = create.items, .remove = remove.items, .conflicts = conflicts.items };
}

const t = std.testing;

test "tokens and account ids" {
    try t.expect(accountToken("cfat_abc"));
    try t.expect(!accountToken("cfut_abc"));
    try t.expect(!accountToken("Ab12cd"));
    try t.expect(validAccount("11dae778e61a9ce2d2ca76b739cc3743"));
    try t.expect(!validAccount("11dae778e61a9ce2d2ca76b739cc374"));
    try t.expect(!validAccount("11dae778e61a9ce2d2ca76b739cc374z"));
}

test "a name belongs to the longest zone it ends with" {
    const list = [_]Zone{ .{ .id = "1", .name = "example.com" }, .{ .id = "2", .name = "shop.example.com" }, .{ .id = "3", .name = "other.dev" } };
    try t.expectEqualStrings("2", zoneFor(&list, "api.shop.example.com").?.id);
    try t.expectEqualStrings("1", zoneFor(&list, "app.example.com").?.id);
    try t.expectEqualStrings("1", zoneFor(&list, "example.com").?.id);
    try t.expectEqualStrings("1", zoneFor(&list, "*.example.com").?.id);
    try t.expect(zoneFor(&list, "notexample.com") == null);
    try t.expect(zoneFor(&list, "example.org") == null);
}

test "the free certificate covers one level" {
    try t.expect(certificateCovers("example.com", "example.com"));
    try t.expect(certificateCovers("example.com", "app.example.com"));
    try t.expect(!certificateCovers("example.com", "x.app.example.com"));
    try t.expect(certificateCovers("example.com", "*.example.com"));
    try t.expect(!certificateCovers("example.com", "*.apps.example.com"));
}

test "a sync writes what is missing and removes only its own records" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target = "abc.cfargotunnel.com";
    const existing = [_]DnsRecord{
        .{ .id = "r1", .type = "CNAME", .name = "web.example.com", .content = target, .proxied = true, .comment = record_comment },
        .{ .id = "r2", .type = "CNAME", .name = "old.example.com", .content = target, .comment = record_comment },
        .{ .id = "r3", .type = "A", .name = "blog.example.com", .content = "203.0.113.9" },
        .{ .id = "r4", .type = "A", .name = "mail.example.com", .content = "203.0.113.10" },
        .{ .id = "r5", .type = "TXT", .name = "api.example.com", .content = "v=spf1" },
    };
    const p = try plan(a, &existing, &.{ "web.example.com", "api.example.com", "blog.example.com" }, target);
    try t.expectEqual(@as(usize, 1), p.create.len);
    try t.expectEqualStrings("api.example.com", p.create[0]);
    try t.expectEqual(@as(usize, 1), p.remove.len);
    try t.expectEqualStrings("r2", p.remove[0].id);
    try t.expectEqual(@as(usize, 1), p.conflicts.len);
    try t.expectEqualStrings("r3", p.conflicts[0].id);
}

test "a foreign name needs a CNAME and its ownership record" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ch: CustomHostname = .{ .hostname = "app.example.org", .ownership_verification = .{ .name = "_cf-custom-hostname.app.example.org", .type = "txt", .value = "1234-abcd" } };
    const recs = try foreignRecords(a, "app.example.org", "pharbor-origin.mine.com", ch);
    try t.expectEqual(@as(usize, 2), recs.len);
    try t.expectEqualStrings("CNAME", recs[0].type);
    try t.expectEqualStrings("pharbor-origin.mine.com", recs[0].content);
    try t.expectEqualStrings("_cf-custom-hostname.app.example.org", recs[1].name);
    try t.expect(!ch.active());
    try t.expect((CustomHostname{ .status = "active", .ssl = .{ .status = "active" } }).active());
}

test "the routes end with Cloudflare's required catch-all" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const body = try routesBody(arena.allocator(), &.{.{ .hostname = "app.example.com", .service = "http://10.88.0.1:8080" }});
    try t.expectEqualStrings(
        \\{"config":{"ingress":[{"hostname":"app.example.com","service":"http://10.88.0.1:8080"},{"service":"http_status:404"}]}}
    , body);
}
