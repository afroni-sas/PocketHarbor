//! Secrets at rest, one-time codes and the encodings they need.

const std = @import("std");
const sys = @import("sys.zig");
const linux = sys.linux;
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

pub const Key = [Aead.key_length]u8;

pub fn random(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.getrandom(buf[off..].ptr, buf.len - off, 0);
        if (linux.errno(rc) != .SUCCESS) continue;
        off += rc;
    }
}

pub fn hex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{x}", .{bytes});
}

pub fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: [32]u8 = undefined;
    Sha256.hash(data, &out, .{});
    return hex(a, &out);
}

pub fn eqlConstantTime(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    var diff: u8 = 0;
    for (x, y) |p, q| diff |= p ^ q;
    return diff == 0;
}

const b32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// RFC 4648 base32 without padding, as authenticator apps expect.
pub fn base32(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var bits: u32 = 0;
    var nbits: u5 = 0;
    for (data) |byte| {
        bits = (bits << 8) | byte;
        nbits += 8;
        while (nbits >= 5) {
            nbits -= 5;
            try out.append(a, b32[(bits >> nbits) & 31]);
        }
    }
    if (nbits > 0) try out.append(a, b32[(bits << (5 - nbits)) & 31]);
    return out.items;
}

pub fn base32Decode(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var bits: u32 = 0;
    var nbits: u5 = 0;
    for (text) |ch| {
        if (ch == '=' or ch == ' ') continue;
        const v = std.mem.indexOfScalar(u8, b32, std.ascii.toUpper(ch)) orelse return error.BadBase32;
        bits = (bits << 5) | @as(u32, @intCast(v));
        nbits += 5;
        if (nbits >= 8) {
            nbits -= 8;
            try out.append(a, @truncate(bits >> nbits));
        }
    }
    return out.items;
}

/// RFC 6238 with the usual parameters: SHA-1, 30 seconds, 6 digits.
pub fn totp(secret: []const u8, counter: u64) u32 {
    var msg: [8]u8 = undefined;
    std.mem.writeInt(u64, &msg, counter, .big);
    var mac: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&mac, &msg, secret);
    const off = mac[mac.len - 1] & 0x0f;
    const bin = (@as(u32, mac[off] & 0x7f) << 24) | (@as(u32, mac[off + 1]) << 16) |
        (@as(u32, mac[off + 2]) << 8) | mac[off + 3];
    return bin % 1_000_000;
}

pub fn totpCounter() u64 {
    return @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s * 30));
}

/// Checks a code against the current step and its neighbours, for clocks
/// that drift. Returns the step that matched, so it cannot be used twice.
pub fn checkTotp(secret: []const u8, code: []const u8, last_used: u64) ?u64 {
    const want = std.fmt.parseInt(u32, std.mem.trim(u8, code, " "), 10) catch return null;
    const now = totpCounter();
    var step = now - 1;
    while (step <= now + 1) : (step += 1) {
        if (step > last_used and totp(secret, step) == want) return step;
    }
    return null;
}

/// The key that protects secrets on disk, created on first use. It lives
/// next to the data, so it guards against copies of the data alone: backups,
/// logs, a stray `cat`.
pub fn loadKey(root: []const u8) !Key {
    var path_buf: [sys.PATH_MAX]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/master.key", .{root});
    var key: Key = undefined;
    var p = try sys.Path.of(path);
    if (sys.open(p.z(), sys.O_CLOEXEC, 0)) |fd| {
        defer sys.close(fd);
        if (try sys.readFull(fd, &key) == key.len) return key;
        return error.BadKey;
    } else |_| {}
    random(&key);
    const fd = sys.open(p.z(), sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL | sys.O_CLOEXEC, 0o600) catch {
        // Someone else created it first; use theirs.
        return loadKey(root);
    };
    defer sys.close(fd);
    try sys.writeAll(fd, &key);
    return key;
}

const prefix = "enc:v1:";

/// Encrypts `plain` for storage: "enc:v1:" and base64 of nonce, text and tag.
pub fn seal(a: std.mem.Allocator, key: Key, plain: []const u8) ![]u8 {
    const raw = try a.alloc(u8, Aead.nonce_length + plain.len + Aead.tag_length);
    const nonce = raw[0..Aead.nonce_length];
    random(nonce);
    const body = raw[Aead.nonce_length..][0..plain.len];
    const tag = raw[Aead.nonce_length + plain.len ..][0..Aead.tag_length];
    Aead.encrypt(body, tag, plain, "", nonce.*, key);
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, prefix.len + enc.calcSize(raw.len));
    @memcpy(out[0..prefix.len], prefix);
    _ = enc.encode(out[prefix.len..], raw);
    return out;
}

pub fn isSealed(text: []const u8) bool {
    return std.mem.startsWith(u8, text, prefix);
}

pub fn open(a: std.mem.Allocator, key: Key, sealed: []const u8) ![]u8 {
    if (!isSealed(sealed)) return error.NotSealed;
    const dec = std.base64.standard.Decoder;
    const text = sealed[prefix.len..];
    const raw = try a.alloc(u8, try dec.calcSizeForSlice(text));
    try dec.decode(raw, text);
    if (raw.len < Aead.nonce_length + Aead.tag_length) return error.BadSecret;
    const nonce = raw[0..Aead.nonce_length].*;
    const body = raw[Aead.nonce_length .. raw.len - Aead.tag_length];
    const tag = raw[raw.len - Aead.tag_length ..][0..Aead.tag_length].*;
    const plain = try a.alloc(u8, body.len);
    Aead.decrypt(plain, body, tag, "", nonce, key) catch return error.BadSecret;
    return plain;
}

const t = std.testing;

test "TOTP matches RFC 6238" {
    const secret = "12345678901234567890";
    try t.expectEqual(@as(u32, 287082), totp(secret, 59 / 30));
    try t.expectEqual(@as(u32, 81804), totp(secret, 1111111109 / 30));
    try t.expectEqual(@as(u32, 50471), totp(secret, 1111111111 / 30));
}

test "base32 round trip" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", try base32(a, "12345678901234567890"));
    try t.expectEqualStrings("hello!", try base32Decode(a, try base32(a, "hello!")));
}

test "sealed secrets open with their key only" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var key: Key = undefined;
    random(&key);
    const s = try seal(a, key, "postgres://u:p@db/x");
    try t.expect(isSealed(s));
    try t.expectEqualStrings("postgres://u:p@db/x", try open(a, key, s));
    var other = key;
    other[0] ^= 1;
    try t.expectError(error.BadSecret, open(a, other, s));
    var tampered = try a.dupe(u8, s);
    tampered[tampered.len - 3] = if (tampered[tampered.len - 3] == 'A') 'B' else 'A';
    try t.expectError(error.BadSecret, open(a, key, tampered));
}
