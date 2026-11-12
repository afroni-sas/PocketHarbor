//! Whether a service's image has something newer: a newer build of the
//! same tag (its digest changed in the registry), a newer version in the
//! same line (9.0 -> 9.1), or a new major version (18-alpine -> 19-alpine).
//! It asks the image's registry anonymously, as a pull would, and keeps
//! the answers in updates.json for a few hours.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const store_mod = @import("store.zig");
const templates = @import("templates.zig");
const engine = @import("engine.zig");
const Store = store_mod.Store;
const Allocator = std.mem.Allocator;

pub const Ref = struct {
    /// The host the API answers on: registry-1.docker.io for Docker Hub.
    host: []const u8,
    repo: []const u8,
    tag: []const u8,
    /// How the image is written, without its tag: to write another tag.
    name: []const u8,
};

/// "postgres:18-alpine", "ghcr.io/me/app:1.2": where to ask. An image
/// pinned by digest never changes, so it has no update.
pub fn parseRef(a: Allocator, image: []const u8) ?Ref {
    if (std.mem.indexOfScalar(u8, image, '@') != null) return null;
    const slash = std.mem.lastIndexOfScalar(u8, image, '/');
    const colon = std.mem.lastIndexOfScalar(u8, image, ':');
    const has_tag = colon != null and (slash == null or colon.? > slash.?);
    const name = if (has_tag) image[0..colon.?] else image;
    const tag = if (has_tag) image[colon.? + 1 ..] else "latest";
    var host: []const u8 = "registry-1.docker.io";
    var repo = name;
    if (std.mem.indexOfScalar(u8, name, '/')) |first| {
        const head = name[0..first];
        if (std.mem.indexOfAny(u8, head, ".:") != null or std.mem.eql(u8, head, "localhost")) {
            host = if (std.mem.eql(u8, head, "docker.io")) "registry-1.docker.io" else head;
            repo = name[first + 1 ..];
        }
    }
    if (std.mem.eql(u8, host, "registry-1.docker.io") and std.mem.indexOfScalar(u8, repo, '/') == null) {
        repo = std.fmt.allocPrint(a, "library/{s}", .{repo}) catch return null;
    }
    return .{ .host = host, .repo = repo, .tag = tag, .name = name };
}

/// A tag read as a version: "v" or nothing, up to four numbers, then a
/// suffix such as "-alpine". Only tags of the same shape compare.
pub const Version = struct {
    prefix: []const u8,
    nums: [4]u32 = .{ 0, 0, 0, 0 },
    len: u8 = 0,
    suffix: []const u8,

    pub fn parse(tag: []const u8) ?Version {
        var rest = tag;
        var prefix: []const u8 = "";
        if (rest.len > 0 and rest[0] == 'v') {
            prefix = "v";
            rest = rest[1..];
        }
        var v: Version = .{ .prefix = prefix, .suffix = "" };
        var i: usize = 0;
        while (v.len < 4) {
            const start = i;
            while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
            if (i == start) return null;
            v.nums[v.len] = std.fmt.parseInt(u32, rest[start..i], 10) catch return null;
            v.len += 1;
            if (i < rest.len and rest[i] == '.' and i + 1 < rest.len and std.ascii.isDigit(rest[i + 1])) {
                i += 1;
                continue;
            }
            break;
        }
        v.suffix = rest[i..];
        if (v.suffix.len > 0 and v.suffix[0] != '-') return null;
        return v;
    }

    fn sameShape(a: Version, b: Version) bool {
        return a.len == b.len and std.mem.eql(u8, a.prefix, b.prefix) and std.mem.eql(u8, a.suffix, b.suffix);
    }

    fn newerThan(a: Version, b: Version) bool {
        for (0..a.len) |k| {
            if (a.nums[k] != b.nums[k]) return a.nums[k] > b.nums[k];
        }
        return false;
    }
};

pub const Found = struct { newer: []const u8 = "", major: []const u8 = "" };

/// Among `tags`, the highest of the same shape in the same line (same first
/// number), and the highest with a higher first number.
pub fn pick(current: []const u8, tags: []const []const u8) Found {
    const cur = Version.parse(current) orelse return .{};
    var out: Found = .{};
    var best_newer: ?Version = null;
    var best_major: ?Version = null;
    for (tags) |tag| {
        const v = Version.parse(tag) orelse continue;
        if (!v.sameShape(cur) or !v.newerThan(cur)) continue;
        if (v.nums[0] == cur.nums[0]) {
            if (best_newer == null or v.newerThan(best_newer.?)) {
                best_newer = v;
                out.newer = tag;
            }
        } else if (best_major == null or v.newerThan(best_major.?)) {
            best_major = v;
            out.major = tag;
        }
    }
    return out;
}

// The registry ------------------------------------------------------------------

const Reply = struct { status: u16, body: []const u8, auth: []const u8 = "", link: []const u8 = "" };

const Registry = struct {
    a: Allocator,
    gpa: Allocator,
    io: std.Io,
    ref: Ref,
    token: []const u8 = "",

    fn fetch(self: *Registry, url: []const u8, accept: []const u8) !Reply {
        var http: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer http.deinit();
        const auth = if (self.token.len > 0) try std.fmt.allocPrint(self.a, "Bearer {s}", .{self.token}) else "";
        var req = try http.request(.GET, try std.Uri.parse(url), .{
            .keep_alive = false,
            .headers = .{
                .accept_encoding = .omit,
                .user_agent = .{ .override = "pocketharbor" },
                .authorization = if (auth.len > 0) .{ .override = auth } else .omit,
            },
            .extra_headers = &.{.{ .name = "Accept", .value = accept }},
        });
        defer req.deinit();
        try req.sendBodiless();
        var head_buf: [16384]u8 = undefined;
        var resp = try req.receiveHead(&head_buf);
        var reply: Reply = .{ .status = @intFromEnum(resp.head.status), .body = "" };
        // The head lives in the reader's buffer: copy what is needed first.
        var it = resp.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) reply.auth = try self.a.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "link")) reply.link = try self.a.dupe(u8, h.value);
        }
        var transfer: [16384]u8 = undefined;
        const rd = resp.reader(&transfer);
        var body: std.ArrayList(u8) = .empty;
        var buf: [16384]u8 = undefined;
        while (body.items.len < 8 << 20) {
            const n = try rd.readSliceShort(&buf);
            if (n == 0) break;
            try body.appendSlice(self.a, buf[0..n]);
        }
        reply.body = body.items;
        return reply;
    }

    /// GET, with the anonymous pull token the registry asks for.
    fn get(self: *Registry, path: []const u8, accept: []const u8) !Reply {
        const url = if (std.mem.startsWith(u8, path, "https://")) path else try std.fmt.allocPrint(self.a, "https://{s}{s}", .{ self.ref.host, path });
        var reply = try self.fetch(url, accept);
        if (reply.status == 401 and self.token.len == 0 and reply.auth.len > 0) {
            self.token = try self.tokenFor(reply.auth);
            reply = try self.fetch(url, accept);
        }
        if (reply.status == 401 or reply.status == 403) return error.Private;
        if (reply.status == 404) return error.NotFound;
        if (reply.status != 200) return error.RegistryError;
        return reply;
    }

    fn param(header: []const u8, key: []const u8) []const u8 {
        var it = std.mem.splitScalar(u8, header, ',');
        while (it.next()) |raw| {
            const part = std.mem.trim(u8, raw, " ");
            const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            var k = part[0..eq];
            if (std.mem.lastIndexOfScalar(u8, k, ' ')) |sp| k = k[sp + 1 ..];
            if (!std.ascii.eqlIgnoreCase(k, key)) continue;
            return std.mem.trim(u8, part[eq + 1 ..], "\"");
        }
        return "";
    }

    fn tokenFor(self: *Registry, challenge: []const u8) ![]const u8 {
        const realm = param(challenge, "realm");
        if (realm.len == 0) return error.Private;
        const service = param(challenge, "service");
        const url = try std.fmt.allocPrint(self.a, "{s}?service={s}&scope=repository:{s}:pull", .{ realm, service, self.ref.repo });
        const reply = try self.fetch(url, "application/json");
        if (reply.status != 200) return error.Private;
        const Doc = struct { token: []const u8 = "", access_token: []const u8 = "" };
        const doc = std.json.parseFromSliceLeaky(Doc, self.a, reply.body, .{ .ignore_unknown_fields = true }) catch return error.Private;
        return if (doc.token.len > 0) doc.token else doc.access_token;
    }

    /// Every tag, page by page as the Link header leads.
    fn tags(self: *Registry) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var path = try std.fmt.allocPrint(self.a, "/v2/{s}/tags/list?n=1000", .{self.ref.repo});
        var pages: u32 = 0;
        while (pages < 30) : (pages += 1) {
            const reply = try self.get(path, "application/json");
            const Doc = struct { tags: ?[]const []const u8 = null };
            const doc = std.json.parseFromSliceLeaky(Doc, self.a, reply.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.RegistryError;
            if (doc.tags) |list| try out.appendSlice(self.a, list);
            // Link: </v2/x/tags/list?last=y&n=1000>; rel="next"
            const start = std.mem.indexOfScalar(u8, reply.link, '<') orelse break;
            const end = std.mem.indexOfScalarPos(u8, reply.link, start, '>') orelse break;
            if (std.mem.indexOf(u8, reply.link, "rel=\"next\"") == null) break;
            path = try self.a.dupe(u8, reply.link[start + 1 .. end]);
        }
        return out.items;
    }

    /// The digest of the tag's image for this device's processor, as an
    /// image id: what a pull of it would give.
    fn imageId(self: *Registry, tag: []const u8) ![]const u8 {
        const accept = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json";
        var reply = try self.get(try std.fmt.allocPrint(self.a, "/v2/{s}/manifests/{s}", .{ self.ref.repo, tag }), accept);
        const Doc = struct {
            manifests: ?[]const struct { digest: []const u8, platform: struct { architecture: []const u8 = "", os: []const u8 = "" } = .{} } = null,
            config: ?struct { digest: []const u8 } = null,
        };
        var doc = std.json.parseFromSliceLeaky(Doc, self.a, reply.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.RegistryError;
        if (doc.manifests) |list| {
            const arch = switch (builtin.cpu.arch) {
                .aarch64 => "arm64",
                .x86_64 => "amd64",
                .arm => "arm",
                else => "amd64",
            };
            var digest: []const u8 = "";
            for (list) |m| if (std.mem.eql(u8, m.platform.os, "linux") and std.mem.eql(u8, m.platform.architecture, arch)) {
                digest = m.digest;
                break;
            };
            if (digest.len == 0) return error.NotFound;
            reply = try self.get(try std.fmt.allocPrint(self.a, "/v2/{s}/manifests/{s}", .{ self.ref.repo, digest }), accept);
            doc = std.json.parseFromSliceLeaky(Doc, self.a, reply.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.RegistryError;
        }
        const config = doc.config orelse return error.RegistryError;
        return strip(config.digest);
    }
};

fn strip(digest: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, digest, "sha256:")) digest["sha256:".len..] else digest;
}

// Checks ------------------------------------------------------------------------

pub const Check = struct {
    image: []const u8,
    /// The image id deployed when it was checked.
    local: []const u8 = "",
    checked_at: i64 = 0,
    /// The tag's image changed in the registry: deploying pulls it.
    build: bool = false,
    /// A newer version in the same line, as a full image name.
    newer: []const u8 = "",
    /// A newer major version, as a full image name.
    major: []const u8 = "",
    /// Why it could not be checked, if it could not.
    @"error": []const u8 = "",

    pub fn available(c: Check) bool {
        return c.build or c.newer.len > 0 or c.major.len > 0;
    }
};

const File = struct { checks: []const Check = &.{} };
const fresh_s = 6 * 3600;

fn load(store: Store) File {
    const data = sys.readFileAlloc(store.a, store.path("updates.json"), 4 << 20) catch return .{};
    return std.json.parseFromSliceLeaky(File, store.a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
}

fn save(store: Store, done: Check) void {
    const old = load(store);
    var list: std.ArrayList(Check) = .empty;
    for (old.checks) |c| if (!std.mem.eql(u8, c.image, done.image)) list.append(store.a, c) catch return;
    list.append(store.a, done) catch return;
    const data = std.json.Stringify.valueAlloc(store.a, File{ .checks = list.items }, .{}) catch return;
    sys.writeFileAtomic(store.path("updates.json"), data, 0o600) catch {};
}

/// The last check of `image`, if it still holds for what is deployed.
pub fn cached(store: Store, image: []const u8, local: []const u8) ?Check {
    for (load(store).checks) |c| {
        if (!std.mem.eql(u8, c.image, image)) continue;
        if (local.len > 0 and c.local.len > 0 and !std.mem.eql(u8, c.local, local)) return null;
        return c;
    }
    return null;
}

/// Asks the registry about `image`, deployed as `local` (an image id, or
/// empty when unknown), unless a recent answer is kept.
pub fn check(a: Allocator, gpa: Allocator, io: std.Io, store: Store, image: []const u8, local: []const u8, force: bool) Check {
    const now: i64 = @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s));
    if (!force) if (cached(store, image, local)) |c| if (now - c.checked_at < fresh_s) return c;
    var out: Check = .{ .image = image, .local = strip(local), .checked_at = now };
    const ref = parseRef(a, image) orelse {
        out.@"error" = "pinned by digest";
        return out;
    };
    var reg: Registry = .{ .a = a, .gpa = gpa, .io = io, .ref = ref };
    if (out.local.len > 0) {
        if (reg.imageId(ref.tag)) |id| {
            out.build = !std.mem.eql(u8, id, out.local);
        } else |e| out.@"error" = message(e);
    }
    if (Version.parse(ref.tag) != null) {
        if (reg.tags()) |all| {
            var found = pick(ref.tag, all);
            // MongoDB 5 and later do not start on older processors.
            if (std.mem.eql(u8, ref.repo, "library/mongo") and found.major.len > 0 and !modernMongo()) found.major = "";
            if (found.newer.len > 0) out.newer = std.fmt.allocPrint(a, "{s}:{s}", .{ ref.name, found.newer }) catch "";
            if (found.major.len > 0) out.major = std.fmt.allocPrint(a, "{s}:{s}", .{ ref.name, found.major }) catch "";
        } else |e| if (out.@"error".len == 0) {
            out.@"error" = message(e);
        }
    }
    save(store, out);
    return out;
}

fn modernMongo() bool {
    const info = sys.readFileAlloc(std.heap.page_allocator, "/proc/cpuinfo", 1 << 20) catch return true;
    defer std.heap.page_allocator.free(info);
    return templates.runsModernMongo(info);
}

fn message(e: anyerror) []const u8 {
    return switch (e) {
        error.Private => "the registry wants credentials to say",
        error.NotFound => "the registry does not know this image",
        else => "the registry could not be reached",
    };
}

/// Checks every service's image a few minutes after the start, then every
/// six hours: the dashboard shows what it finds without waiting.
pub fn watch(root: []const u8, bin: [:0]const u8, envp: engine.Envp, io: std.Io) void {
    sys.sleepMs(120_000);
    while (true) {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const store: Store = .{ .a = a, .root = root };
        var eng: engine.Engine = .{ .a = a, .bin = bin, .envp = envp };
        const list = store.list() catch &.{};
        for (list) |svc| {
            if (svc.image.len == 0) continue;
            const local = if (svc.container.len > 0) eng.imageIdOf(svc.container) else "";
            _ = check(a, std.heap.smp_allocator, io, store, svc.image, local, false);
            sys.sleepMs(2000);
        }
        sys.sleepMs(fresh_s * 1000);
    }
}

const t = std.testing;

test "image names" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pg = parseRef(a, "postgres:18-alpine").?;
    try t.expectEqualStrings("registry-1.docker.io", pg.host);
    try t.expectEqualStrings("library/postgres", pg.repo);
    try t.expectEqualStrings("18-alpine", pg.tag);
    try t.expectEqualStrings("postgres", pg.name);
    const gh = parseRef(a, "ghcr.io/me/app").?;
    try t.expectEqualStrings("ghcr.io", gh.host);
    try t.expectEqualStrings("me/app", gh.repo);
    try t.expectEqualStrings("latest", gh.tag);
    const local = parseRef(a, "localhost:5000/app:1.0").?;
    try t.expectEqualStrings("localhost:5000", local.host);
    try t.expectEqualStrings("1.0", local.tag);
    const vg = parseRef(a, "versity/versitygw:v1.11.0").?;
    try t.expectEqualStrings("versity/versitygw", vg.repo);
    try t.expect(parseRef(a, "nginx@sha256:abc") == null);
}

test "newer versions of the same shape" {
    const tags = [_][]const u8{ "9.0", "9.0.8", "9.1", "9.2-rc0", "8.3", "10.0", "10.1", "latest", "9.1-noble" };
    const m = pick("9.0", &tags);
    try t.expectEqualStrings("9.1", m.newer);
    try t.expectEqualStrings("10.1", m.major);
    const pg = pick("18-alpine", &[_][]const u8{ "18-alpine", "19-alpine", "19", "18.6-alpine", "20-bookworm" });
    try t.expectEqualStrings("", pg.newer);
    try t.expectEqualStrings("19-alpine", pg.major);
    const v = pick("v1.11.0", &[_][]const u8{ "v1.12.0", "v1.11.1", "1.13.0", "v2.0.0", "latest" });
    try t.expectEqualStrings("v1.12.0", v.newer);
    try t.expectEqualStrings("v2.0.0", v.major);
    const none = pick("latest", &[_][]const u8{ "1.0", "2.0" });
    try t.expectEqualStrings("", none.newer);
    try t.expectEqualStrings("", none.major);
}
