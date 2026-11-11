//! Tells people when something happens: a deploy fails or succeeds, a
//! service crashes, a cron run or a backup fails, or a service stays above
//! a CPU, memory or volume threshold. Alerts go to Discord, Slack, email
//! (through Resend's API) or any webhook.
//!
//!   <root>/alerts.json   channels and thresholds; URLs and keys are sealed
//!   <root>/alerts.log    the latest deliveries, one JSON line each

const std = @import("std");
const sys = @import("sys.zig");
const crypto = @import("crypto.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Allocator = std.mem.Allocator;

pub const Kind = enum { discord, slack, email, webhook };

/// Every event a channel can subscribe to.
pub const event_kinds = [_][]const u8{
    "deploy_failed",
    "deploy_succeeded",
    "crashed",
    "cron_failed",
    "backup_failed",
    "high_cpu",
    "high_memory",
    "high_disk",
};

pub const default_events = [_][]const u8{ "deploy_failed", "crashed", "cron_failed", "backup_failed", "high_cpu", "high_memory", "high_disk" };

pub const Channel = struct {
    id: []const u8,
    name: []const u8,
    kind: Kind,
    /// Sealed. The webhook URL; for email, the Resend API key.
    target: []const u8 = "",
    /// Sealed. A plain webhook's signing secret.
    signing: []const u8 = "",
    email_from: []const u8 = "",
    email_to: []const []const u8 = &.{},
    events: []const []const u8 = &.{},
    /// Only events of these projects; empty means all of them.
    projects: []const []const u8 = &.{},
    enabled: bool = true,
};

/// Zero turns a threshold off.
pub const Thresholds = struct {
    /// Average over five minutes, in percent of one core.
    cpu_percent: u32 = 0,
    memory_mb: u32 = 0,
    disk_mb: u32 = 0,
};

pub const Config = struct {
    channels: []const Channel = &.{},
    thresholds: Thresholds = .{},
};

pub const Severity = enum { info, warning, critical };

pub const Event = struct {
    kind: []const u8,
    /// One line: "web failed to deploy".
    title: []const u8,
    detail: []const u8 = "",
    project: []const u8 = "",
    environment: []const u8 = "",
    service: []const u8 = "",
    severity: Severity = .critical,
    at: i64 = 0,
};

pub fn configPath(store: Store) []const u8 {
    return store.path("alerts.json");
}

pub fn logPath(store: Store) []const u8 {
    return store.path("alerts.log");
}

pub fn load(store: Store) Config {
    const data = sys.readFileAlloc(store.a, configPath(store), 1 << 20) catch return .{};
    return std.json.parseFromSliceLeaky(Config, store.a, data, .{ .ignore_unknown_fields = true }) catch .{};
}

pub fn save(store: Store, cfg: Config) !void {
    const data = try std.json.Stringify.valueAlloc(store.a, cfg, .{ .whitespace = .indent_2 });
    try sys.writeFileAtomic(configPath(store), data, 0o600);
}

pub fn knownEvent(kind: []const u8) bool {
    for (event_kinds) |k| if (std.mem.eql(u8, k, kind)) return true;
    return false;
}

/// Where a channel of this kind may post.
pub fn validTarget(kind: Kind, url: []const u8) bool {
    return switch (kind) {
        .discord => std.mem.startsWith(u8, url, "https://discord.com/api/webhooks/") or
            std.mem.startsWith(u8, url, "https://discordapp.com/api/webhooks/") or
            std.mem.startsWith(u8, url, "https://canary.discord.com/api/webhooks/"),
        .slack => std.mem.startsWith(u8, url, "https://hooks.slack.com/"),
        .webhook => (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://")) and
            (std.Uri.parse(url) catch null) != null,
        .email => url.len > 0,
    };
}

fn wants(ch: Channel, ev: Event) bool {
    if (!ch.enabled) return false;
    var subscribed = false;
    for (ch.events) |k| subscribed = subscribed or std.mem.eql(u8, k, ev.kind);
    if (!subscribed) return false;
    if (ch.projects.len == 0 or ev.project.len == 0) return true;
    for (ch.projects) |p| if (std.mem.eql(u8, p, ev.project)) return true;
    return false;
}

pub const Delivery = struct {
    t: i64,
    channel: []const u8,
    name: []const u8,
    event: []const u8,
    title: []const u8,
    ok: bool,
    @"error": []const u8 = "",
};

/// Sends `ev` to every channel that wants it. Failures are logged, never
/// returned: an alert must not break what it reports on.
pub fn notify(a: Allocator, store: Store, key: crypto.Key, io: std.Io, ev_in: Event) void {
    var ev = ev_in;
    if (ev.at == 0) ev.at = @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s));
    const cfg = load(store);
    for (cfg.channels) |ch| {
        if (!wants(ch, ev)) continue;
        const result = deliver(a, io, key, ch, ev);
        record(a, store, .{
            .t = ev.at,
            .channel = ch.id,
            .name = ch.name,
            .event = ev.kind,
            .title = ev.title,
            .ok = result == null,
            .@"error" = result orelse "",
        });
    }
}

fn record(a: Allocator, store: Store, d: Delivery) void {
    const line = std.json.Stringify.valueAlloc(a, d, .{}) catch return;
    const file = logPath(store);
    var p = sys.Path.of(file) catch return;
    const fd = sys.open(p.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND, 0o600) catch return;
    sys.writeAll(fd, line) catch {};
    sys.writeAll(fd, "\n") catch {};
    var st: sys.Stat = undefined;
    sys.stat(p.z(), &st) catch {};
    sys.close(fd);
    if (st.size > 256 * 1024) {
        const data = sys.readFileAlloc(a, file, 1 << 20) catch return;
        const cut = std.mem.indexOfScalarPos(u8, data, data.len / 2, '\n') orelse return;
        sys.writeFileAtomic(file, data[cut + 1 ..], 0o600) catch {};
    }
}

/// Null when it went through, else why not.
pub fn deliver(a: Allocator, io: std.Io, key: crypto.Key, ch: Channel, ev: Event) ?[]const u8 {
    const target = crypto.open(a, key, ch.target) catch return "the channel's address could not be decrypted";
    const status = switch (ch.kind) {
        .discord => post(a, io, target, discordBody(a, ev) catch return "out of memory", &.{}),
        .slack => post(a, io, target, slackBody(a, ev) catch return "out of memory", &.{}),
        .webhook => blk: {
            const body = webhookBody(a, ev) catch return "out of memory";
            var headers: std.ArrayList(std.http.Header) = .empty;
            headers.append(a, .{ .name = "X-PocketHarbor-Event", .value = ev.kind }) catch {};
            if (ch.signing.len > 0) {
                const secret = crypto.open(a, key, ch.signing) catch return "the signing secret could not be decrypted";
                headers.append(a, .{ .name = "X-PocketHarbor-Signature", .value = signature(a, secret, body) catch return "out of memory" }) catch {};
            }
            break :blk post(a, io, target, body, headers.items);
        },
        .email => blk: {
            const auth = std.fmt.allocPrint(a, "Bearer {s}", .{target}) catch return "out of memory";
            const body = emailBody(a, ch, ev) catch return "out of memory";
            const api = emailApi();
            break :blk post(a, io, api, body, &.{.{ .name = "Authorization", .value = auth }});
        },
    } catch |e| return switch (e) {
        error.ConnectionRefused => "the connection was refused",
        error.UnknownHostName => "the host name does not resolve",
        else => @errorName(e),
    };
    if (status >= 200 and status < 300) return null;
    return std.fmt.allocPrint(a, "the server answered {d}", .{status}) catch "the server refused it";
}

/// Resend's endpoint; replaceable for tests.
var email_api_override: ?[]const u8 = null;

pub fn setEmailApi(url: []const u8) void {
    if (url.len > 0) email_api_override = url;
}

fn emailApi() []const u8 {
    return email_api_override orelse "https://api.resend.com/emails";
}

fn post(a: Allocator, io: std.Io, url: []const u8, body: []const u8, extra: []const std.http.Header) !u16 {
    var http: std.http.Client = .{ .allocator = a, .io = io };
    defer http.deinit();
    var req = try http.request(.POST, try std.Uri.parse(url), .{
        .keep_alive = false,
        .headers = .{
            .accept_encoding = .omit,
            .user_agent = .{ .override = "pocketharbor" },
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = extra,
    });
    defer req.deinit();
    try req.sendBodyComplete(try a.dupe(u8, body));
    var head_buf: [8192]u8 = undefined;
    const resp = try req.receiveHead(&head_buf);
    return @intFromEnum(resp.head.status);
}

pub fn signature(a: Allocator, secret: []const u8, body: []const u8) ![]const u8 {
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, body, secret);
    return std.fmt.allocPrint(a, "sha256={s}", .{try crypto.hex(a, &mac)});
}

fn where(a: Allocator, ev: Event) ![]const u8 {
    if (ev.project.len == 0) return "";
    if (ev.service.len == 0) return std.fmt.allocPrint(a, "{s} / {s}", .{ ev.project, ev.environment });
    return std.fmt.allocPrint(a, "{s} / {s} / {s}", .{ ev.project, ev.environment, ev.service });
}

fn color(sev: Severity) u32 {
    return switch (sev) {
        .info => 0x4fb286,
        .warning => 0xe0a630,
        .critical => 0xd9534f,
    };
}

fn isoTime(a: Allocator, at: i64) ![]const u8 {
    var buf: [40]u8 = undefined;
    const text = sys.fmtTime(&buf, @as(i128, at) * std.time.ns_per_s);
    return a.dupe(u8, text);
}

pub fn discordBody(a: Allocator, ev: Event) ![]const u8 {
    const Field = struct { name: []const u8, value: []const u8, @"inline": bool = true };
    var fields: std.ArrayList(Field) = .empty;
    if (ev.project.len > 0) try fields.append(a, .{ .name = "Project", .value = try std.fmt.allocPrint(a, "{s} / {s}", .{ ev.project, ev.environment }) });
    if (ev.service.len > 0) try fields.append(a, .{ .name = "Service", .value = ev.service });
    return std.json.Stringify.valueAlloc(a, .{
        .username = "PocketHarbor",
        .embeds = &.{.{
            .title = ev.title,
            .description = ev.detail,
            .color = color(ev.severity),
            .fields = fields.items,
            .timestamp = try isoTime(a, ev.at),
        }},
    }, .{});
}

/// Slack treats &, < and > as markup.
fn slackEscape(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| switch (ch) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        else => try out.append(a, ch),
    };
    return out.items;
}

pub fn slackBody(a: Allocator, ev: Event) ![]const u8 {
    const place = try where(a, ev);
    const text = try std.fmt.allocPrint(a, "*{s}*{s}{s}{s}{s}", .{
        try slackEscape(a, ev.title),
        if (ev.detail.len > 0) "\n" else "",
        try slackEscape(a, ev.detail),
        if (place.len > 0) "\n_" else "",
        if (place.len > 0) try std.fmt.allocPrint(a, "{s}_", .{try slackEscape(a, place)}) else "",
    });
    return std.json.Stringify.valueAlloc(a, .{ .text = text }, .{});
}

pub fn webhookBody(a: Allocator, ev: Event) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .event = ev.kind,
        .title = ev.title,
        .detail = ev.detail,
        .project = ev.project,
        .environment = ev.environment,
        .service = ev.service,
        .severity = @tagName(ev.severity),
        .at = ev.at,
    }, .{});
}

pub fn emailBody(a: Allocator, ch: Channel, ev: Event) ![]const u8 {
    const place = try where(a, ev);
    const text = try std.fmt.allocPrint(a, "{s}\n\n{s}{s}{s}\n\nAt {s}.\n-- PocketHarbor", .{
        ev.title,
        ev.detail,
        if (place.len > 0) "\n" else "",
        place,
        try isoTime(a, ev.at),
    });
    return std.json.Stringify.valueAlloc(a, .{
        .from = ch.email_from,
        .to = ch.email_to,
        .subject = try std.fmt.allocPrint(a, "[PocketHarbor] {s}", .{ev.title}),
        .text = text,
    }, .{});
}

const t = std.testing;

test "channels pick their events and projects" {
    const ch: Channel = .{ .id = "1", .name = "ops", .kind = .slack, .events = &.{ "crashed", "deploy_failed" }, .projects = &.{"shop"} };
    try t.expect(wants(ch, .{ .kind = "crashed", .title = "", .project = "shop" }));
    try t.expect(!wants(ch, .{ .kind = "crashed", .title = "", .project = "blog" }));
    try t.expect(!wants(ch, .{ .kind = "high_cpu", .title = "", .project = "shop" }));
    var off = ch;
    off.enabled = false;
    try t.expect(!wants(off, .{ .kind = "crashed", .title = "", .project = "shop" }));
}

test "targets" {
    try t.expect(validTarget(.discord, "https://discord.com/api/webhooks/1/abc"));
    try t.expect(!validTarget(.discord, "https://example.com/api/webhooks/1/abc"));
    try t.expect(validTarget(.slack, "https://hooks.slack.com/services/T/B/x"));
    try t.expect(!validTarget(.slack, "http://hooks.slack.com/services/T/B/x"));
    try t.expect(validTarget(.webhook, "http://10.0.0.2:9000/hook"));
    try t.expect(!validTarget(.webhook, "ftp://example.com"));
}

test "payloads" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ev: Event = .{ .kind = "crashed", .title = "web crashed", .detail = "exit code 1 <oops> & more", .project = "shop", .environment = "production", .service = "web", .at = 0 };
    const slack = try slackBody(a, ev);
    try t.expect(std.mem.indexOf(u8, slack, "*web crashed*") != null);
    try t.expect(std.mem.indexOf(u8, slack, "&lt;oops&gt; &amp; more") != null);
    try t.expect(std.mem.indexOf(u8, slack, "_shop / production / web_") != null);
    const discord = try discordBody(a, ev);
    try t.expect(std.mem.indexOf(u8, discord, "\"title\":\"web crashed\"") != null);
    try t.expect(std.mem.indexOf(u8, discord, "\"color\":14242639") != null);
    try t.expect(std.mem.indexOf(u8, discord, "\"timestamp\":\"1970-01-01T00:00:00") != null);
    const hook = try webhookBody(a, ev);
    try t.expect(std.mem.indexOf(u8, hook, "\"event\":\"crashed\"") != null);
    try t.expect(std.mem.indexOf(u8, hook, "\"severity\":\"critical\"") != null);
    const ch: Channel = .{ .id = "1", .name = "mail", .kind = .email, .email_from = "Harbor <a@b.c>", .email_to = &.{"me@b.c"} };
    const mail = try emailBody(a, ch, ev);
    try t.expect(std.mem.indexOf(u8, mail, "\"subject\":\"[PocketHarbor] web crashed\"") != null);
    try t.expect(std.mem.indexOf(u8, mail, "\"to\":[\"me@b.c\"]") != null);
}

test "webhook signature" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // HMAC-SHA256("key", "The quick brown fox jumps over the lazy dog")
    try t.expectEqualStrings(
        "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
        try signature(arena.allocator(), "key", "The quick brown fox jumps over the lazy dog"),
    );
}
