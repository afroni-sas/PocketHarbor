//! Deploy on push without setting anything up: once the phone has a public
//! name (Cloudflare connected) and a GitHub token that may manage webhooks,
//! each repository that a service deploys from gets PocketHarbor's webhook,
//! and loses it when nothing deploys from it any more.

const std = @import("std");
const sys = @import("sys.zig");
const crypto = @import("crypto.zig");
const github = @import("github.zig");
const edge = @import("edge.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Allocator = std.mem.Allocator;

pub const Status = enum {
    /// The webhook is in place.
    ready,
    /// The phone has no public name for GitHub to call: Cloudflare is not connected.
    needs_cloudflare,
    /// No GitHub token is saved.
    needs_token,
    /// The token may not manage this repository's webhooks.
    denied,
    /// GitHub could not be reached, or refused for another reason.
    failed,
};

pub const Entry = struct {
    /// "owner/name", as the services name it.
    repo: []const u8,
    /// The webhook PocketHarbor made, to update or remove; 0 when none.
    hook_id: u64 = 0,
    status: Status = .needs_cloudflare,
    detail: []const u8 = "",
};

pub const State = struct {
    /// Where the webhooks send pushes, when there is a public name.
    target: []const u8 = "",
    repos: []const Entry = &.{},
};

const file = "github-hooks.json";

pub fn load(store: Store) State {
    const data = sys.readFileAlloc(store.a, store.path(file), 1 << 20) catch return .{};
    return std.json.parseFromSliceLeaky(State, store.a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
}

fn save(store: Store, state: State) void {
    const data = std.json.Stringify.valueAlloc(store.a, state, .{}) catch return;
    sys.writeFileAtomic(store.path(file), data, 0o600) catch {};
}

/// The address GitHub calls: the dashboard's public name, which Cloudflare
/// serves (its relay on workers.dev, or a zone through the tunnel).
pub fn target(a: Allocator, store: Store) ![]const u8 {
    if (!edge.connected(store)) return "";
    const s = store.settings();
    if (s.panel_domain.len == 0) return "";
    return std.fmt.allocPrint(a, "https://{s}{s}", .{ s.panel_domain, github.webhook_path });
}

/// The repositories that services deploy from on push, each once.
fn wanted(a: Allocator, store: Store) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try store.list()) |svc| {
        if (svc.repo.len == 0 or !svc.auto_deploy) continue;
        var seen = false;
        for (out.items) |r| seen = seen or std.ascii.eqlIgnoreCase(r, svc.repo);
        if (!seen) try out.append(a, svc.repo);
    }
    return out.items;
}

fn previousOf(prev: State, repo: []const u8) ?Entry {
    for (prev.repos) |e| if (std.ascii.eqlIgnoreCase(e.repo, repo)) return e;
    return null;
}

/// Puts each wanted repository's webhook in place, pointed at `target`, and
/// removes the ones PocketHarbor made that nothing needs. `secret` signs the
/// deliveries. Never fails: what went wrong is kept per repository.
pub fn sync(a: Allocator, gpa: Allocator, io: std.Io, key: crypto.Key, store: Store, secret: []const u8, api: []const u8) !State {
    const prev = load(store);
    const repos = try wanted(a, store);
    const to = try target(a, store);
    const sealed = store.settings().github_token;
    const token: []const u8 = if (sealed.len == 0) "" else crypto.open(a, key, sealed) catch "";
    var client: github.Client = .{ .gpa = gpa, .io = io, .token = token };
    if (api.len > 0) client.api = api;

    var out: std.ArrayList(Entry) = .empty;
    for (repos) |repo| {
        const before = previousOf(prev, repo);
        var entry: Entry = .{ .repo = repo, .hook_id = if (before) |b| b.hook_id else 0 };
        if (token.len == 0) {
            // A webhook made with an earlier token still delivers: pushes
            // keep deploying, until it points at a name that is gone.
            entry.status = if (entry.hook_id != 0 and to.len > 0 and std.mem.eql(u8, prev.target, to)) .ready else .needs_token;
        } else if (to.len == 0) {
            entry.status = .needs_cloudflare;
            // A webhook pointed at a name that is gone only fails: remove it.
            if (entry.hook_id != 0) {
                var msg: []const u8 = "";
                client.deleteHook(a, repo, entry.hook_id, &msg) catch {};
                entry.hook_id = 0;
            }
        } else {
            putOne(a, client, &entry, to, secret);
        }
        try out.append(a, entry);
    }
    // Repositories nothing deploys from any more.
    for (prev.repos) |e| {
        if (e.hook_id == 0 or token.len == 0) continue;
        var still = false;
        for (repos) |r| still = still or std.ascii.eqlIgnoreCase(r, e.repo);
        if (still) continue;
        var msg: []const u8 = "";
        client.deleteHook(a, e.repo, e.hook_id, &msg) catch {};
    }
    const state: State = .{ .target = to, .repos = out.items };
    save(store, state);
    return state;
}

fn putOne(a: Allocator, client: github.Client, entry: *Entry, to: []const u8, secret: []const u8) void {
    var msg: []const u8 = "";
    const existing = client.hooks(a, entry.repo, &msg) catch |e| return fail(entry, e, msg);
    // The one PocketHarbor made, or one that already calls the phone.
    var id: ?u64 = null;
    for (existing) |h| {
        if (h.id == entry.hook_id or std.mem.endsWith(u8, h.config.url, github.webhook_path)) {
            id = h.id;
            break;
        }
    }
    entry.hook_id = client.putHook(a, entry.repo, id, to, secret, &msg) catch |e| return fail(entry, e, msg);
    entry.status = .ready;
    entry.detail = "";
}

fn fail(entry: *Entry, err: anyerror, msg: []const u8) void {
    entry.status = if (err == error.GitHubDenied) .denied else .failed;
    entry.detail = if (err == error.GitHubDenied)
        "the GitHub token may not manage this repository's webhooks: give it Webhooks: Read and write, and access to the repository"
    else if (msg.len > 0) msg else @errorName(err);
}

/// What the service's Auto Deploy shows.
pub fn statusOf(store: Store, svc: store_mod.Service) ?Entry {
    if (svc.repo.len == 0) return null;
    const state = load(store);
    if (previousOf(state, svc.repo)) |e| return e;
    // Not synced yet: say what is missing.
    if (store.settings().github_token.len == 0) return .{ .repo = svc.repo, .status = .needs_token };
    if (!edge.connected(store)) return .{ .repo = svc.repo, .status = .needs_cloudflare };
    return .{ .repo = svc.repo, .status = .failed, .detail = "not set up yet" };
}

test "the webhook target needs a public name" {
    try std.testing.expect(std.mem.endsWith(u8, "https://x.example.workers.dev/__pharbor/webhooks/github", github.webhook_path));
}
