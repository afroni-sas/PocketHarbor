//! Accounts, sessions and API tokens.
//!
//!   <root>/users.json             accounts; TOTP secrets are encrypted
//!   <root>/tokens.json            API tokens, by their SHA-256 only
//!   <root>/sessions/<sha256>      one file per signed-in browser

const std = @import("std");
const sys = @import("sys.zig");
const crypto = @import("crypto.zig");
const Store = @import("store.zig").Store;
const Allocator = std.mem.Allocator;
const argon2 = std.crypto.pwhash.argon2;

pub const session_cookie = "ph_session";
pub const session_days = 30;
const token_prefix = "ph_";

pub const User = struct {
    id: []const u8,
    email: []const u8,
    password: []const u8,
    totp_secret: []const u8 = "",
    totp_enabled: bool = false,
    totp_last: u64 = 0,
    created_at: i64 = 0,
};

pub const Token = struct {
    id: []const u8,
    name: []const u8,
    hash: []const u8,
    /// The first characters, so that a token can be recognised in a list.
    hint: []const u8,
    created_at: i64 = 0,
    last_used_at: i64 = 0,
};

const Session = struct { user: []const u8, created_at: i64, expires_at: i64 };

const Users = struct { users: []const User = &.{} };
const Tokens = struct { tokens: []const Token = &.{} };

/// Who made a request.
pub const Who = struct {
    user: ?User = null,
    token: ?[]const u8 = null,

    pub fn name(self: Who) []const u8 {
        if (self.user) |u| return u.email;
        return self.token orelse "";
    }
};

fn nowS() i64 {
    return @intCast(@divFloor(sys.nowNs(), std.time.ns_per_s));
}

// OWASP's minimum for argon2id: 19 MiB, two passes. About 0.1 s on a phone.
const params: argon2.Params = .{ .t = 2, .m = 19 * 1024, .p = 1 };

pub const Auth = struct {
    store: Store,
    io: std.Io,
    key: crypto.Key,

    fn a(self: Auth) Allocator {
        return self.store.a;
    }

    pub fn users(self: Auth) []const User {
        const data = sys.readFileAlloc(self.a(), self.store.path("users.json"), 1 << 20) catch return &.{};
        const doc = std.json.parseFromSliceLeaky(Users, self.a(), data, .{ .ignore_unknown_fields = true }) catch return &.{};
        return doc.users;
    }

    fn saveUsers(self: Auth, list: []const User) !void {
        const data = try std.json.Stringify.valueAlloc(self.a(), Users{ .users = list }, .{ .whitespace = .indent_2 });
        try sys.writeFileAtomic(self.store.path("users.json"), data, 0o600);
    }

    pub fn findUser(self: Auth, email: []const u8) ?User {
        for (self.users()) |u| {
            if (std.ascii.eqlIgnoreCase(u.email, email)) return u;
        }
        return null;
    }

    pub fn userById(self: Auth, id: []const u8) ?User {
        for (self.users()) |u| {
            if (std.mem.eql(u8, u.id, id)) return u;
        }
        return null;
    }

    pub fn hashPassword(self: Auth, password: []const u8) ![]const u8 {
        var buf: [128]u8 = undefined;
        const s = try argon2.strHash(password, .{ .allocator = self.a(), .params = params }, &buf, self.io);
        return self.a().dupe(u8, s);
    }

    fn passwordMatches(self: Auth, hash: []const u8, password: []const u8) bool {
        argon2.strVerify(hash, password, .{ .allocator = self.a() }, self.io) catch return false;
        return true;
    }

    pub fn addUser(self: Auth, email: []const u8, password: []const u8) !User {
        if (password.len < 8) return error.PasswordTooShort;
        if (std.mem.indexOfScalar(u8, email, '@') == null or email.len > 254) return error.BadEmail;
        const lock = try self.store.lock();
        defer self.store.unlock(lock);
        if (self.findUser(email) != null) return error.UserExists;
        var id: [8]u8 = undefined;
        crypto.random(&id);
        const user: User = .{
            .id = try crypto.hex(self.a(), &id),
            .email = try self.a().dupe(u8, email),
            .password = try self.hashPassword(password),
            .created_at = nowS(),
        };
        var list: std.ArrayList(User) = .empty;
        try list.appendSlice(self.a(), self.users());
        try list.append(self.a(), user);
        try self.saveUsers(list.items);
        return user;
    }

    pub fn updateUser(self: Auth, user: User) !void {
        const lock = try self.store.lock();
        defer self.store.unlock(lock);
        var list: std.ArrayList(User) = .empty;
        for (self.users()) |u| try list.append(self.a(), if (std.mem.eql(u8, u.id, user.id)) user else u);
        try self.saveUsers(list.items);
    }

    pub fn removeUser(self: Auth, id: []const u8) !void {
        const lock = try self.store.lock();
        defer self.store.unlock(lock);
        var list: std.ArrayList(User) = .empty;
        for (self.users()) |u| {
            if (!std.mem.eql(u8, u.id, id)) try list.append(self.a(), u);
        }
        try self.saveUsers(list.items);
    }

    pub const LoginError = error{ BadCredentials, CodeRequired, BadCode };

    /// Checks a password, and the one-time code once 2FA is on.
    pub fn login(self: Auth, email: []const u8, password: []const u8, code: ?[]const u8) (LoginError || anyerror)!User {
        // Spend the same time whether or not the account exists.
        const user = self.findUser(email) orelse {
            _ = self.passwordMatches("$argon2id$v=19$m=19456,t=2,p=1$c29tZXNhbHRzb21lc2FsdA$e6FwH8Kp8m1V+1pZz2kz3kT6xzYxw6mPq3m3cZ4k3gE", password);
            return error.BadCredentials;
        };
        if (!self.passwordMatches(user.password, password)) return error.BadCredentials;
        if (!user.totp_enabled) return user;
        const c = code orelse return error.CodeRequired;
        var updated = user;
        updated.totp_last = try self.verifyCode(user, c);
        try self.updateUser(updated);
        return updated;
    }

    /// Returns the time step used, which may not be used again.
    pub fn verifyCode(self: Auth, user: User, code: []const u8) !u64 {
        const secret = try self.totpSecret(user);
        return crypto.checkTotp(secret, code, user.totp_last) orelse error.BadCode;
    }

    pub fn totpSecret(self: Auth, user: User) ![]const u8 {
        if (user.totp_secret.len == 0) return error.NoSecret;
        return crypto.open(self.a(), self.key, user.totp_secret);
    }

    /// Starts enrolment: a new secret, used only once confirmed by a code.
    pub fn beginTotp(self: Auth, user: User) ![]const u8 {
        var secret: [20]u8 = undefined;
        crypto.random(&secret);
        var updated = user;
        updated.totp_secret = try crypto.seal(self.a(), self.key, &secret);
        updated.totp_enabled = false;
        try self.updateUser(updated);
        return crypto.base32(self.a(), &secret);
    }

    pub fn enableTotp(self: Auth, user: User, code: []const u8) !void {
        var updated = user;
        updated.totp_last = try self.verifyCode(user, code);
        updated.totp_enabled = true;
        try self.updateUser(updated);
    }

    pub fn disableTotp(self: Auth, user: User) !void {
        var updated = user;
        updated.totp_enabled = false;
        updated.totp_secret = "";
        updated.totp_last = 0;
        try self.updateUser(updated);
    }

    fn sessionPath(self: Auth, token: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a(), "{s}/sessions/{s}", .{ self.store.root, try crypto.sha256Hex(self.a(), token) });
    }

    /// Returns the cookie value. Only its hash is stored.
    pub fn createSession(self: Auth, user: User) ![]const u8 {
        try sys.mkdirP(self.store.path("sessions"), 0o700);
        var raw: [32]u8 = undefined;
        crypto.random(&raw);
        const token = try crypto.hex(self.a(), &raw);
        const s: Session = .{ .user = user.id, .created_at = nowS(), .expires_at = nowS() + session_days * 86400 };
        const data = try std.json.Stringify.valueAlloc(self.a(), s, .{});
        try sys.writeFileAtomic(try self.sessionPath(token), data, 0o600);
        return token;
    }

    pub fn endSession(self: Auth, token: []const u8) void {
        var p = sys.Path.of(self.sessionPath(token) catch return) catch return;
        sys.unlink(p.z()) catch {};
    }

    /// Signs every browser of a user out, after a password change for instance.
    pub fn endAllSessions(self: Auth, user_id: []const u8) void {
        var d = sys.Path.of(self.store.path("sessions")) catch return;
        var it = sys.DirIter.open_(d.z()) catch return;
        defer it.deinit();
        while (it.next() catch null) |ent| {
            const file = std.fmt.allocPrint(self.a(), "{s}/sessions/{s}", .{ self.store.root, ent.name }) catch continue;
            const data = sys.readFileAlloc(self.a(), file, 4096) catch continue;
            const s = std.json.parseFromSliceLeaky(Session, self.a(), data, .{}) catch continue;
            if (!std.mem.eql(u8, s.user, user_id)) continue;
            var p = sys.Path.of(file) catch continue;
            sys.unlink(p.z()) catch {};
        }
    }

    pub fn sessionUser(self: Auth, token: []const u8) ?User {
        if (token.len != 64) return null;
        const path = self.sessionPath(token) catch return null;
        const data = sys.readFileAlloc(self.a(), path, 4096) catch return null;
        const s = std.json.parseFromSliceLeaky(Session, self.a(), data, .{}) catch return null;
        if (s.expires_at < nowS()) {
            self.endSession(token);
            return null;
        }
        return self.userById(s.user);
    }

    pub fn tokens(self: Auth) []const Token {
        const data = sys.readFileAlloc(self.a(), self.store.path("tokens.json"), 1 << 20) catch return &.{};
        const doc = std.json.parseFromSliceLeaky(Tokens, self.a(), data, .{ .ignore_unknown_fields = true }) catch return &.{};
        return doc.tokens;
    }

    fn saveTokens(self: Auth, list: []const Token) !void {
        const data = try std.json.Stringify.valueAlloc(self.a(), Tokens{ .tokens = list }, .{ .whitespace = .indent_2 });
        try sys.writeFileAtomic(self.store.path("tokens.json"), data, 0o600);
    }

    /// Returns the token itself, which is shown once and never stored.
    pub fn createToken(self: Auth, name: []const u8) !struct { token: []const u8, info: Token } {
        var raw: [24]u8 = undefined;
        crypto.random(&raw);
        const secret = try std.fmt.allocPrint(self.a(), "{s}{s}", .{ token_prefix, try crypto.base32(self.a(), &raw) });
        var id: [6]u8 = undefined;
        crypto.random(&id);
        const info: Token = .{
            .id = try crypto.hex(self.a(), &id),
            .name = try self.a().dupe(u8, name),
            .hash = try crypto.sha256Hex(self.a(), secret),
            .hint = secret[0..9],
            .created_at = nowS(),
        };
        const lock = try self.store.lock();
        defer self.store.unlock(lock);
        var list: std.ArrayList(Token) = .empty;
        try list.appendSlice(self.a(), self.tokens());
        try list.append(self.a(), info);
        try self.saveTokens(list.items);
        return .{ .token = secret, .info = info };
    }

    pub fn removeToken(self: Auth, id: []const u8) !bool {
        const lock = try self.store.lock();
        defer self.store.unlock(lock);
        var list: std.ArrayList(Token) = .empty;
        var found = false;
        for (self.tokens()) |tk| {
            if (std.mem.eql(u8, tk.id, id)) {
                found = true;
            } else {
                try list.append(self.a(), tk);
            }
        }
        try self.saveTokens(list.items);
        return found;
    }

    pub fn checkToken(self: Auth, secret: []const u8) ?Token {
        if (!std.mem.startsWith(u8, secret, token_prefix)) return null;
        const hash = crypto.sha256Hex(self.a(), secret) catch return null;
        for (self.tokens()) |tk| {
            if (crypto.eqlConstantTime(tk.hash, hash)) return tk;
        }
        return null;
    }
};

/// Slows down password guessing: a few failures per address, then a pause.
pub const Throttle = struct {
    const slots = 64;
    const max_failures = 8;
    const window_s = 300;

    mutex: std.atomic.Mutex = .unlocked,
    keys: [slots][46]u8 = undefined,
    lens: [slots]u8 = @splat(0),
    counts: [slots]u32 = @splat(0),
    since: [slots]i64 = @splat(0),

    fn slot(_: *Throttle, ip: []const u8) usize {
        const h = std.hash.Wyhash.hash(0, ip);
        return @intCast(h % slots);
    }

    fn lock(self: *Throttle) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn blocked(self: *Throttle, ip: []const u8) bool {
        self.lock();
        defer self.mutex.unlock();
        const i = self.slot(ip);
        if (!std.mem.eql(u8, self.keys[i][0..self.lens[i]], ip)) return false;
        if (nowS() - self.since[i] > window_s) return false;
        return self.counts[i] >= max_failures;
    }

    pub fn failed(self: *Throttle, ip: []const u8) void {
        self.lock();
        defer self.mutex.unlock();
        const i = self.slot(ip);
        const n = @min(ip.len, 46);
        if (!std.mem.eql(u8, self.keys[i][0..self.lens[i]], ip[0..n]) or nowS() - self.since[i] > window_s) {
            @memcpy(self.keys[i][0..n], ip[0..n]);
            self.lens[i] = @intCast(n);
            self.counts[i] = 0;
            self.since[i] = nowS();
        }
        self.counts[i] += 1;
    }

    pub fn succeeded(self: *Throttle, ip: []const u8) void {
        self.lock();
        defer self.mutex.unlock();
        const i = self.slot(ip);
        if (std.mem.eql(u8, self.keys[i][0..self.lens[i]], ip)) self.counts[i] = 0;
    }
};
