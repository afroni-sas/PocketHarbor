//! Public access through Cloudflare Tunnel, so that a phone behind a carrier's
//! NAT can serve the internet. The connector runs as a container; TLS ends at
//! Cloudflare, and traffic reaches the proxy through the host gateway.

const std = @import("std");
const sys = @import("sys.zig");
const engine = @import("engine.zig");
const Store = @import("store.zig").Store;
const Engine = engine.Engine;

const container = "pharbor-tunnel";
const image = "cloudflare/cloudflared:latest";
/// What the private network calls the phone's loopback (`--host-gateway`).
const gateway = "10.88.0.1";

/// Where a tunnel's public hostnames must point.
pub fn originUrl(store: Store) ![]const u8 {
    return std.fmt.allocPrint(store.a, "http://{s}:{d}", .{ gateway, store.settings().proxy_port });
}

fn findUrl(text: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, text, ".trycloudflare.com") orelse return null;
    const start = std.mem.lastIndexOf(u8, text[0..i], "https://") orelse return null;
    if (std.mem.indexOfAny(u8, text[start..i], " \n\"|") != null) return null;
    return text[start .. i + ".trycloudflare.com".len];
}

/// A temporary public URL, with no Cloudflare account. It answers for one
/// service, since the hostname is chosen by Cloudflare.
pub fn quick(store: Store, eng: *Engine, id: []const u8) !void {
    var s = store.settings();
    s.default_service = id;
    s.tunnel_id = "";
    try store.saveSettings(s);
    store.syncRoutes();

    eng.remove(container);
    const args = [_][]const u8{
        "run",           "-d",     "--name",     container, "--restart", "always", "--host-gateway",
        image,           "tunnel", "--protocol", protocol,  "--url",     try originUrl(store),
    };
    if (try eng.run(&args) != 0) return error.TunnelFailed;

    sys.print("Waiting for Cloudflare to assign a URL...\n", .{});
    var waited: u32 = 0;
    while (waited < 120) : (waited += 1) {
        if (findUrl(eng.logs(container))) |url| {
            sys.print("{s} -> {s}\n", .{ url, id });
            return;
        }
        const info = eng.inspect(container) orelse break;
        if (!info.alive()) break;
        sys.sleepMs(500);
    }
    sys.eprint("error: no URL was assigned\n{s}", .{eng.logs(container)});
    return error.TunnelFailed;
}

/// Reads the tunnel's id out of a token, which is base64 JSON.
fn tunnelId(a: std.mem.Allocator, token: []const u8) ?[]const u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(token) catch return null;
    const buf = a.alloc(u8, size) catch return null;
    decoder.decode(buf, token) catch return null;
    const Doc = struct { t: []const u8 };
    const doc = std.json.parseFromSliceLeaky(Doc, a, buf, .{ .ignore_unknown_fields = true }) catch return null;
    return doc.t;
}

/// Where cloudflared finds the token, inside its container.
const token_dir = "/etc/pharbor-tunnel";

/// cloudflared prefers QUIC, over UDP. A QUIC connection keeps its socket
/// across reconnections, and once the network changed under it (the
/// device slept, Wi-Fi came back) every retry fails on that dead socket.
/// HTTP/2 runs over TCP and opens a fresh connection each time; it also
/// passes where UDP is filtered.
const protocol = "http2";

/// A permanent tunnel. Its token goes in a file only this user can read,
/// which the container gets read-only: on a command line or in the
/// container's environment, any process listing would show it.
pub fn named(store: Store, eng: *Engine, token: []const u8) !void {
    const a = store.a;
    eng.remove(container);
    const dir = store.path("tunnel");
    try sys.mkdirP(dir, 0o700);
    try sys.writeFileAtomic(store.path("tunnel/token"), token, 0o600);
    const mount = try std.fmt.allocPrint(a, "{s}:{s}:ro", .{ dir, token_dir });
    const args = [_][]const u8{
        "run",    "-d",       "--name", container, "--restart", "always",       "--host-gateway",
        "-v",     mount,      image,    "tunnel",  "--protocol", protocol, "run", "--token-file",
        token_dir ++ "/token",
    };
    if (try eng.run(&args) != 0) return error.TunnelFailed;

    var waited: u32 = 0;
    while (waited < 60) : (waited += 1) {
        if (std.mem.indexOf(u8, eng.logs(container), "Registered tunnel connection") != null) break;
        const info = eng.inspect(container) orelse return error.TunnelFailed;
        if (!info.alive()) {
            sys.eprint("error: the tunnel stopped\n{s}", .{eng.logs(container)});
            return error.TunnelFailed;
        }
        sys.sleepMs(500);
    } else {
        sys.eprint("warning: the tunnel has not connected yet; see pharbor tunnel status\n", .{});
    }
    sys.print("Tunnel running. In the Cloudflare dashboard, point each public hostname at:\n  {s}\n", .{try originUrl(store)});
    if (tunnelId(a, token)) |id| {
        sys.print("For a domain hosted elsewhere, add a CNAME to:\n  {s}.cfargotunnel.com\n", .{id});
        // The dashboard shows each custom domain the record it needs.
        var s = store.settings();
        s.tunnel_id = id;
        store.saveSettings(s) catch {};
    }
}

/// Whether the tunnel's container runs.
pub fn running(eng: *Engine) bool {
    const info = eng.inspect(container) orelse return false;
    return info.alive();
}

pub fn stop(store: Store, eng: *Engine) void {
    eng.remove(container);
    var token = sys.Path.of(store.path("tunnel/token")) catch null;
    if (token) |*p| sys.unlink(p.z()) catch {};
    var s = store.settings();
    if (s.default_service.len > 0 or s.tunnel_id.len > 0) {
        s.default_service = "";
        s.tunnel_id = "";
        store.saveSettings(s) catch {};
        store.syncRoutes();
    }
    sys.print("Tunnel stopped\n", .{});
}

pub fn status(eng: *Engine) void {
    const info = eng.inspect(container) orelse {
        sys.print("No tunnel\n", .{});
        return;
    };
    sys.print("{s}\n", .{info.status});
    const logs = eng.logs(container);
    if (findUrl(logs)) |url| sys.print("{s}\n", .{url});
    var last: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, logs, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "Registered tunnel connection") != null) last = line;
    }
    if (last.len > 0) sys.print("{s}\n", .{last});
}

const t = std.testing;

test "finds the URL in cloudflared's banner" {
    const text = "2026 INF |  https://calm-river-1a2b.trycloudflare.com                  |\n";
    try t.expectEqualStrings("https://calm-river-1a2b.trycloudflare.com", findUrl(text).?);
    try t.expect(findUrl("nothing here") == null);
}

/// Whether the tunnel's container runs cloudflared with `protocol`.
fn current(eng: *Engine) bool {
    const argv = eng.argvOf(container) orelse return true;
    for (argv) |arg| if (std.mem.eql(u8, arg, protocol)) return true;
    return false;
}

/// Made again a tunnel made by an earlier version, with QUIC: from the
/// token kept for it, so nothing is asked of Cloudflare.
pub fn upgrade(store: Store, eng: *Engine) void {
    if (current(eng)) return;
    const token = sys.readFileAlloc(store.a, store.path("tunnel/token"), 16 << 10) catch return;
    sys.print("tunnel: starting cloudflared again over {s}\n", .{protocol});
    named(store, eng, std.mem.trim(u8, token, " \r\n\t")) catch |e| sys.eprint("tunnel: {s}\n", .{@errorName(e)});
}

/// Keeps cloudflared connected for good: an old tunnel is made again over
/// HTTP/2, and when the device wakes up the connector starts again at once
/// rather than waiting for its connections to be found dead.
pub fn watch(root: []const u8, bin: [:0]const u8, envp: engine.Envp) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var sleep = sys.SleepWatch.init();
    var first = true;
    while (true) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const store: Store = .{ .a = a, .root = root };
        var eng: Engine = .{ .a = a, .bin = bin, .envp = envp };
        if (first) {
            first = false;
            if (store.settings().tunnel_id.len > 0) {
                upgrade(store, &eng);
                // Stopped with PocketHarbor or by a restart of the device.
                if (eng.inspect(container)) |info| if (!info.alive()) {
                    sys.print("tunnel: starting cloudflared again\n", .{});
                    if (!eng.start(container)) sys.eprint("tunnel: cloudflared did not start\n", .{});
                };
            }
        }
        sys.sleepMs(2000);
        if (!sleep.check(10 * std.time.ns_per_s)) continue;
        const info = eng.inspect(container) orelse continue;
        if (!info.alive()) continue;
        sys.print("tunnel: the device slept; restarting cloudflared\n", .{});
        if (!eng.restart(container)) sys.eprint("tunnel: cloudflared did not restart\n", .{});
    }
}

