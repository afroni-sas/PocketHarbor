//! Fetching code from GitHub, and checking the webhooks it sends.

const std = @import("std");
const sys = @import("sys.zig");
const crypto = @import("crypto.zig");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Commit = struct { sha: []const u8, message: []const u8 };

pub const Repo = struct {
    full_name: []const u8,
    private: bool = false,
    default_branch: []const u8 = "main",
    description: ?[]const u8 = null,
    pushed_at: ?[]const u8 = null,
};

/// "owner/name", from that or from a github.com URL.
pub fn normalizeRepo(input: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, input, " /");
    for ([_][]const u8{ "https://github.com/", "http://github.com/", "github.com/" }) |p| {
        if (std.mem.startsWith(u8, s, p)) s = s[p.len..];
    }
    if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - 4];
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return null;
    if (slash == 0 or slash == s.len - 1 or std.mem.indexOfScalarPos(u8, s, slash + 1, '/') != null) return null;
    for (s) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-_./", ch) == null) return null;
    }
    return s;
}

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    token: []const u8 = "",
    /// Another API root, for GitHub Enterprise: https://HOST/api/v3.
    api: []const u8 = "https://api.github.com",

    fn get(self: Client, a: Allocator, url: []const u8, accept: []const u8, sink: ?i32) ![]u8 {
        var http: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer http.deinit();
        const auth = if (self.token.len > 0) try std.fmt.allocPrint(a, "Bearer {s}", .{self.token}) else "";
        var req = try http.request(.GET, try std.Uri.parse(url), .{
            .keep_alive = false,
            .headers = .{
                .accept_encoding = .omit,
                .user_agent = .{ .override = "pocketharbor" },
                .authorization = if (auth.len > 0) .{ .override = auth } else .omit,
            },
            .extra_headers = &.{
                .{ .name = "Accept", .value = accept },
                .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
            },
        });
        defer req.deinit();
        try req.sendBodiless();
        var head_buf: [16384]u8 = undefined;
        var resp = try req.receiveHead(&head_buf);
        const status = resp.head.status;
        var transfer: [65536]u8 = undefined;
        const rd = resp.reader(&transfer);
        var body: std.ArrayList(u8) = .empty;
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = try rd.readSliceShort(&buf);
            if (n == 0) break;
            if (sink != null and status == .ok) {
                try sys.writeAll(sink.?, buf[0..n]);
            } else if (body.items.len < 1 << 20) {
                try body.appendSlice(a, buf[0..n]);
            }
        }
        if (status == .not_found) return error.RepoNotFound;
        if (status == .unauthorized or status == .forbidden) return error.GitHubDenied;
        if (status != .ok) return error.GitHubError;
        return body.items;
    }

    /// The repositories the token can read, most recently pushed first.
    pub fn repos(self: Client, a: Allocator) ![]Repo {
        const url = try std.fmt.allocPrint(a, "{s}/user/repos?per_page=100&sort=pushed", .{self.api});
        const body = try self.get(a, url, "application/vnd.github+json", null);
        return std.json.parseFromSliceLeaky([]Repo, a, body, .{ .ignore_unknown_fields = true });
    }

    pub fn latestCommit(self: Client, a: Allocator, repo: []const u8, branch: []const u8) !Commit {
        const url = try std.fmt.allocPrint(a, "{s}/repos/{s}/commits/{s}", .{ self.api, repo, branch });
        const body = try self.get(a, url, "application/vnd.github+json", null);
        const Doc = struct { sha: []const u8, commit: struct { message: []const u8 = "" } };
        const doc = try std.json.parseFromSliceLeaky(Doc, a, body, .{ .ignore_unknown_fields = true });
        const first_line = std.mem.indexOfScalar(u8, doc.commit.message, '\n') orelse doc.commit.message.len;
        return .{ .sha = doc.sha, .message = doc.commit.message[0..first_line] };
    }

    /// Downloads the repository at `sha` as a .tar.gz file.
    pub fn tarball(self: Client, a: Allocator, repo: []const u8, sha: []const u8, dest: []const u8) !void {
        const url = try std.fmt.allocPrint(a, "{s}/repos/{s}/tarball/{s}", .{ self.api, repo, sha });
        var p = try sys.Path.of(dest);
        const fd = try sys.open(p.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC | sys.O_CLOEXEC, 0o600);
        defer sys.close(fd);
        _ = try self.get(a, url, "application/vnd.github+json", fd);
    }
};

/// GitHub signs each delivery with the webhook's secret.
pub fn verifySignature(secret: []const u8, body: []const u8, header: []const u8) bool {
    const prefix = "sha256=";
    if (!std.mem.startsWith(u8, header, prefix)) return false;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, secret);
    var want: [HmacSha256.mac_length * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&want, "{x}", .{&mac}) catch return false;
    return crypto.eqlConstantTime(&want, header[prefix.len..]);
}

fn parseOctal(field: []const u8) u64 {
    var v: u64 = 0;
    for (field) |ch| {
        if (ch < '0' or ch > '7') break;
        v = v * 8 + (ch - '0');
    }
    return v;
}

fn cstr(raw: []const u8) []const u8 {
    return raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];
}

/// A path inside the archive, without its first directory, refused if it
/// tries to leave the destination.
fn inside(a: Allocator, name: []const u8) !?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return null;
    const rest = std.mem.trim(u8, name[slash + 1 ..], "/");
    if (rest.len == 0) return null;
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.UnsafePath;
    }
    return try a.dupe(u8, rest);
}

/// Whether a symlink at `at` pointing to `target` stays within the tree.
fn linkStaysInside(at: []const u8, target: []const u8) bool {
    if (target.len == 0 or target[0] == '/') return false;
    var depth: i32 = @intCast(std.mem.count(u8, at, "/"));
    var it = std.mem.splitScalar(u8, target, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            depth -= 1;
            if (depth < 0) return false;
        } else if (part.len > 0 and !std.mem.eql(u8, part, ".")) {
            depth += 1;
        }
    }
    return true;
}

/// Extracts a GitHub tarball into `dest`, dropping its top directory.
/// Returns the number of files written.
pub fn extract(gpa: Allocator, io: std.Io, archive: []const u8, dest: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const file = try std.Io.Dir.openFileAbsolute(io, archive, .{});
    defer file.close(io);
    const in_buf = try a.alloc(u8, 1 << 16);
    var file_reader = file.readerStreaming(io, in_buf);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    var gz = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, window);
    const r = &gz.reader;

    try sys.mkdirP(dest, 0o755);
    var block: [512]u8 = undefined;
    var long_name: ?[]const u8 = null;
    var count: usize = 0;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try r.readSliceShort(&block);
        if (n == 0) break;
        if (n < 512) return error.TruncatedArchive;
        if (std.mem.allEqual(u8, &block, 0)) break;
        const typ = block[156];
        const size = parseOctal(block[124..136]);
        const padding = (512 - size % 512) % 512;

        if (typ == 'x' or typ == 'g' or typ == 'L') {
            const data = try a.alloc(u8, @intCast(size));
            try r.readSliceAll(data);
            try r.discardAll(@intCast(padding));
            if (typ == 'L') long_name = cstr(data);
            if (typ == 'x') {
                // Only the path record matters here.
                var it = std.mem.splitScalar(u8, data, '\n');
                while (it.next()) |rec| {
                    const sp = std.mem.indexOfScalar(u8, rec, ' ') orelse continue;
                    const kv = rec[sp + 1 ..];
                    if (std.mem.startsWith(u8, kv, "path=")) long_name = kv[5..];
                }
            }
            continue;
        }

        var name: []const u8 = undefined;
        if (long_name) |l| {
            name = l;
        } else {
            const prefix = cstr(block[345..500]);
            const base = cstr(block[0..100]);
            name = if (prefix.len > 0) try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, base }) else base;
        }
        long_name = null;
        const rel = try inside(a, name);
        const has_data = typ == '0' or typ == 0 or typ == '7';

        if (rel) |path| {
            const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dest, path });
            if (typ == '5') {
                try sys.mkdirP(full, 0o755);
            } else if (typ == '2') {
                const target = cstr(block[157..257]);
                if (linkStaysInside(path, target)) {
                    if (std.fs.path.dirname(full)) |dir| try sys.mkdirP(dir, 0o755);
                    var tp = try sys.Path.of(target);
                    var fp = try sys.Path.of(full);
                    sys.symlink(tp.z(), fp.z()) catch {};
                }
            } else if (has_data) {
                if (std.fs.path.dirname(full)) |dir| try sys.mkdirP(dir, 0o755);
                var fp = try sys.Path.of(full);
                const mode: u32 = @truncate(parseOctal(block[100..108]));
                const fd = try sys.open(fp.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC | sys.O_NOFOLLOW | sys.O_CLOEXEC, (mode & 0o755) | 0o600);
                defer sys.close(fd);
                var left = size;
                while (left > 0) {
                    const want: usize = @intCast(@min(left, buf.len));
                    try r.readSliceAll(buf[0..want]);
                    try sys.writeAll(fd, buf[0..want]);
                    left -= want;
                }
                try r.discardAll(@intCast(padding));
                count += 1;
                continue;
            }
        }
        if (has_data) try r.discardAll64(size + padding);
    }
    return count;
}

const t = std.testing;

test "repositories are named owner/name" {
    try t.expectEqualStrings("afroni-sas/app", normalizeRepo("https://github.com/afroni-sas/app.git").?);
    try t.expectEqualStrings("a/b", normalizeRepo("a/b").?);
    try t.expect(normalizeRepo("a") == null);
    try t.expect(normalizeRepo("a/b/c") == null);
    try t.expect(normalizeRepo("a/b c") == null);
}

test "webhook signatures" {
    const sig = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17";
    // The example from GitHub's documentation.
    try t.expect(verifySignature("It's a Secret to Everybody", "Hello, World!", sig));
    try t.expect(!verifySignature("wrong", "Hello, World!", sig));
    try t.expect(!verifySignature("It's a Secret to Everybody", "Hello, World?", sig));
    try t.expect(!verifySignature("It's a Secret to Everybody", "Hello, World!", "sha1=00"));
}

test "archive paths cannot leave the destination" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("src/main.go", (try inside(a, "repo-abc/src/main.go")).?);
    try t.expect((try inside(a, "repo-abc/")) == null);
    try t.expectError(error.UnsafePath, inside(a, "repo-abc/../etc/passwd"));
    try t.expect(linkStaysInside("a/b", "../c"));
    try t.expect(!linkStaysInside("a/b", "../../c"));
    try t.expect(!linkStaysInside("a", "/etc"));
}
