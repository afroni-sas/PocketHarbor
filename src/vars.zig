//! Variables: per service, shared across an environment, and references
//! between them, resolved when a deployment starts.
//!
//!   <root>/variables/<project>.<environment>.json
//!
//! Every value is encrypted on disk. A value may refer to others:
//!   ${{ KEY }}           another variable of the same service
//!   ${{ shared.KEY }}    a shared variable of the environment
//!   ${{ db.KEY }}        a variable of the service `db`, as it resolves there
//! Each service also has PHARBOR_* variables describing it, which others can
//! refer to as well: ${{ db.PHARBOR_PRIVATE_DOMAIN }}.

const std = @import("std");
const sys = @import("sys.zig");
const crypto = @import("crypto.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Service = store_mod.Service;
const Allocator = std.mem.Allocator;

pub const Var = struct { name: []const u8, value: []const u8 };

const File = struct {
    shared: []const Var = &.{},
    services: std.json.ArrayHashMap([]const Var) = .{},
};

pub fn validKey(k: []const u8) bool {
    if (k.len == 0 or k.len > 128) return false;
    if (!std.ascii.isAlphabetic(k[0]) and k[0] != '_') return false;
    for (k) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

/// Reads `.env` text: KEY=VALUE lines, `export`, comments, and single,
/// double or no quotes. Double quotes understand \n, \t, \" and \\.
pub fn parseDotenv(a: Allocator, text: []const u8) ![]Var {
    var out: std.ArrayList(Var) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line[7..], " \t");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.BadLine;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!validKey(key)) return error.BadKey;
        var value = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
        if (value.len > 0 and value[0] == '"') {
            var buf: std.ArrayList(u8) = .empty;
            var i: usize = 1;
            var closed = false;
            while (i < value.len) : (i += 1) {
                const ch = value[i];
                if (ch == '"') {
                    closed = true;
                    break;
                }
                if (ch == '\\' and i + 1 < value.len) {
                    i += 1;
                    try buf.append(a, switch (value[i]) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        else => value[i],
                    });
                } else {
                    try buf.append(a, ch);
                }
            }
            if (!closed) return error.UnclosedQuote;
            value = buf.items;
        } else if (value.len > 0 and value[0] == '\'') {
            const end = std.mem.indexOfScalarPos(u8, value, 1, '\'') orelse return error.UnclosedQuote;
            value = value[1..end];
        } else {
            // An unquoted value ends at a comment.
            if (std.mem.indexOf(u8, value, " #")) |i| value = value[0..i];
            value = std.mem.trimEnd(u8, value, " \t");
        }
        try out.append(a, .{ .name = key, .value = value });
    }
    return out.items;
}

/// Replaces or adds `set`, then removes `unset`.
pub fn merge(a: Allocator, base: []const Var, set: []const Var, unset: []const []const u8) ![]Var {
    var out: std.ArrayList(Var) = .empty;
    outer: for (base) |v| {
        for (unset) |u| if (std.mem.eql(u8, u, v.name)) continue :outer;
        for (set) |s| if (std.mem.eql(u8, s.name, v.name)) continue :outer;
        try out.append(a, v);
    }
    for (set) |s| try out.append(a, s);
    std.mem.sort(Var, out.items, {}, struct {
        fn lt(_: void, x: Var, y: Var) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    return out.items;
}

pub const Vars = struct {
    store: Store,
    key: crypto.Key,

    fn path(self: Vars, project: []const u8, environment: []const u8) []const u8 {
        return std.fmt.allocPrint(self.store.a, "{s}/variables/{s}.{s}.json", .{ self.store.root, project, environment }) catch @panic("OOM");
    }

    fn load(self: Vars, project: []const u8, environment: []const u8) File {
        const data = sys.readFileAlloc(self.store.a, self.path(project, environment), 1 << 24) catch return .{};
        return std.json.parseFromSliceLeaky(File, self.store.a, data, .{ .ignore_unknown_fields = true }) catch .{};
    }

    fn decrypt(self: Vars, list: []const Var) ![]Var {
        const out = try self.store.a.alloc(Var, list.len);
        for (list, 0..) |v, i| {
            out[i] = .{ .name = v.name, .value = if (crypto.isSealed(v.value)) try crypto.open(self.store.a, self.key, v.value) else v.value };
        }
        return out;
    }

    fn encrypt(self: Vars, list: []const Var) ![]Var {
        const out = try self.store.a.alloc(Var, list.len);
        for (list, 0..) |v, i| out[i] = .{ .name = v.name, .value = try crypto.seal(self.store.a, self.key, v.value) };
        return out;
    }

    /// Plain values. `service` null means the shared variables.
    pub fn get(self: Vars, project: []const u8, environment: []const u8, service: ?[]const u8) ![]Var {
        const f = self.load(project, environment);
        if (service) |name| {
            if (f.services.map.get(name)) |list| return self.decrypt(list);
            // Services from before variables had their own store.
            const svc = self.store.load(self.store.idFrom(project, environment, name)) catch return &.{};
            var legacy: std.ArrayList(Var) = .empty;
            for (svc.env) |e| {
                const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
                try legacy.append(self.store.a, .{ .name = e[0..eq], .value = e[eq + 1 ..] });
            }
            return legacy.items;
        }
        return self.decrypt(f.shared);
    }

    /// Replaces a whole set. Callers hold the store lock.
    pub fn put(self: Vars, project: []const u8, environment: []const u8, service: ?[]const u8, list: []const Var) !void {
        for (list) |v| if (!validKey(v.name)) return error.BadKey;
        var f = self.load(project, environment);
        const sealed = try self.encrypt(list);
        if (service) |name| {
            try f.services.map.put(self.store.a, name, sealed);
        } else {
            f.shared = sealed;
        }
        try sys.mkdirP(self.store.path("variables"), 0o700);
        const data = try std.json.Stringify.valueAlloc(self.store.a, f, .{ .whitespace = .indent_2 });
        try sys.writeFileAtomic(self.path(project, environment), data, 0o600);
    }

    pub fn dropService(self: Vars, project: []const u8, environment: []const u8, service: []const u8) void {
        var f = self.load(project, environment);
        _ = f.services.map.orderedRemove(service);
        const data = std.json.Stringify.valueAlloc(self.store.a, f, .{ .whitespace = .indent_2 }) catch return;
        sys.writeFileAtomic(self.path(project, environment), data, 0o600) catch {};
    }

    pub fn dropEnvironment(self: Vars, project: []const u8, environment: []const u8) void {
        var p = sys.Path.of(self.path(project, environment)) catch return;
        sys.unlink(p.z()) catch {};
    }

    /// Copies an environment's variables, for a new environment made from it.
    pub fn copyEnvironment(self: Vars, project: []const u8, from: []const u8, to: []const u8) void {
        const data = sys.readFileAlloc(self.store.a, self.path(project, from), 1 << 24) catch return;
        sys.writeFileAtomic(self.path(project, to), data, 0o600) catch {};
    }

    /// The environment a deployment starts with: references resolved, and
    /// the service's own PHARBOR_* variables added.
    pub fn resolve(self: Vars, svc: Service, warnings: *std.ArrayList([]const u8)) ![]Var {
        const a = self.store.a;
        var scope: Scope = .{ .a = a, .shared = try self.get(svc.project, svc.environment, null), .warnings = warnings };
        for (try self.store.listIn(svc.project, svc.environment)) |other| {
            try scope.services.put(a, other.name, .{
                .vars = try self.get(svc.project, svc.environment, other.name),
                .builtins = try builtins(self.store, other),
            });
        }
        if (!scope.services.contains(svc.name)) {
            try scope.services.put(a, svc.name, .{ .vars = try self.get(svc.project, svc.environment, svc.name), .builtins = try builtins(self.store, svc) });
        }
        return scope.all(svc.name);
    }
};

/// What a service knows about itself, and others can refer to.
pub fn builtins(store: Store, svc: Service) ![]Var {
    const a = store.a;
    const s = store.settings();
    const names = try store.hostnames(svc, s);
    var public: []const u8 = "";
    for (names) |n| {
        if (!std.mem.eql(u8, n, "*") and !std.mem.startsWith(u8, n, "*.")) {
            public = n;
            break;
        }
    }
    const port = try std.fmt.allocPrint(a, "{d}", .{if (svc.port != 0) svc.port else 8080});
    const list = try a.alloc(Var, 6);
    list[0] = .{ .name = "PHARBOR_SERVICE_NAME", .value = svc.name };
    list[1] = .{ .name = "PHARBOR_PROJECT_NAME", .value = svc.project };
    list[2] = .{ .name = "PHARBOR_ENVIRONMENT_NAME", .value = svc.environment };
    list[3] = .{ .name = "PHARBOR_PRIVATE_DOMAIN", .value = store.publicLabel(svc) };
    list[4] = .{ .name = "PHARBOR_PUBLIC_DOMAIN", .value = public };
    list[5] = .{ .name = "PHARBOR_TCP_PORT", .value = port };
    return list;
}

const Entry = struct { vars: []const Var, builtins: []const Var };

const Scope = struct {
    a: Allocator,
    shared: []const Var,
    services: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    warnings: *std.ArrayList([]const u8),

    fn find(list: []const Var, name: []const u8) ?[]const u8 {
        for (list) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
        return null;
    }

    fn all(self: *Scope, service: []const u8) ![]Var {
        const entry = self.services.get(service).?;
        var out: std.ArrayList(Var) = .empty;
        for (entry.builtins) |b| {
            if (find(entry.vars, b.name) == null) try out.append(self.a, b);
        }
        for (entry.vars) |v| try out.append(self.a, .{ .name = v.name, .value = try self.expand(service, v.value, 0) });
        return out.items;
    }

    fn lookup(self: *Scope, service: []const u8, name: []const u8, depth: u8) !?[]const u8 {
        if (std.mem.eql(u8, service, "shared")) {
            const v = find(self.shared, name) orelse return null;
            return try self.expand("shared", v, depth + 1);
        }
        const entry = self.services.get(service) orelse return null;
        if (find(entry.vars, name)) |v| return try self.expand(service, v, depth + 1);
        return find(entry.builtins, name);
    }

    fn expand(self: *Scope, service: []const u8, value: []const u8, depth: u8) anyerror![]const u8 {
        if (std.mem.indexOf(u8, value, "${{") == null) return value;
        if (depth > 8) return error.ReferenceLoop;
        var out: std.ArrayList(u8) = .empty;
        var rest = value;
        while (std.mem.indexOf(u8, rest, "${{")) |start| {
            try out.appendSlice(self.a, rest[0..start]);
            const end = std.mem.indexOfPos(u8, rest, start, "}}") orelse {
                try out.appendSlice(self.a, rest[start..]);
                rest = "";
                break;
            };
            const ref = std.mem.trim(u8, rest[start + 3 .. end], " ");
            rest = rest[end + 2 ..];
            const dot = std.mem.indexOfScalar(u8, ref, '.');
            const target = if (dot) |i| ref[0..i] else service;
            const name = if (dot) |i| ref[i + 1 ..] else ref;
            // Within a shared variable, a bare name means another shared one.
            const resolved = try self.lookup(target, name, depth);
            if (resolved) |v| {
                try out.appendSlice(self.a, v);
            } else {
                try self.warnings.append(self.a, try std.fmt.allocPrint(self.a, "${{{{ {s} }}}} is not defined", .{ref}));
            }
        }
        try out.appendSlice(self.a, rest);
        return out.items;
    }
};

const t = std.testing;

test "reads .env files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const vars = try parseDotenv(arena.allocator(),
        \\# a comment
        \\export A=1
        \\B = two words # trailing comment
        \\C="line\nnext \"quoted\""
        \\D='single # not a comment'
        \\E=
        \\
    );
    try t.expectEqual(@as(usize, 5), vars.len);
    try t.expectEqualStrings("1", vars[0].value);
    try t.expectEqualStrings("two words", vars[1].value);
    try t.expectEqualStrings("line\nnext \"quoted\"", vars[2].value);
    try t.expectEqualStrings("single # not a comment", vars[3].value);
    try t.expectEqualStrings("", vars[4].value);
    try t.expectError(error.BadKey, parseDotenv(arena.allocator(), "1BAD=x"));
    try t.expectError(error.UnclosedQuote, parseDotenv(arena.allocator(), "A=\"open"));
}

test "merge replaces, adds and removes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const out = try merge(arena.allocator(), &.{ .{ .name = "A", .value = "1" }, .{ .name = "B", .value = "2" } }, &.{ .{ .name = "B", .value = "3" }, .{ .name = "C", .value = "4" } }, &.{"A"});
    try t.expectEqual(@as(usize, 2), out.len);
    try t.expectEqualStrings("3", out[0].value);
    try t.expectEqualStrings("C", out[1].name);
}

test "references resolve across services and shared variables" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList([]const u8) = .empty;
    var scope: Scope = .{
        .a = a,
        .shared = &.{ .{ .name = "REGION", .value = "af" }, .{ .name = "ZONE", .value = "${{ REGION }}-1" } },
        .warnings = &warnings,
    };
    try scope.services.put(a, "db", .{
        .vars = &.{
            .{ .name = "PASSWORD", .value = "s3cret" },
            .{ .name = "URL", .value = "postgres://u:${{PASSWORD}}@${{ PHARBOR_PRIVATE_DOMAIN }}:5432/app" },
        },
        .builtins = &.{.{ .name = "PHARBOR_PRIVATE_DOMAIN", .value = "db" }},
    });
    try scope.services.put(a, "api", .{
        .vars = &.{
            .{ .name = "DATABASE_URL", .value = "${{ db.URL }}" },
            .{ .name = "WHERE", .value = "${{shared.ZONE}}" },
            .{ .name = "MISSING", .value = "x${{ db.NOPE }}y" },
        },
        .builtins = &.{.{ .name = "PHARBOR_PRIVATE_DOMAIN", .value = "api" }},
    });
    const out = try scope.all("api");
    try t.expectEqualStrings("PHARBOR_PRIVATE_DOMAIN", out[0].name);
    try t.expectEqualStrings("postgres://u:s3cret@db:5432/app", Scope.find(out, "DATABASE_URL").?);
    try t.expectEqualStrings("af-1", Scope.find(out, "WHERE").?);
    try t.expectEqualStrings("xy", Scope.find(out, "MISSING").?);
    try t.expectEqual(@as(usize, 1), warnings.items.len);
}

test "a loop of references is an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warnings: std.ArrayList([]const u8) = .empty;
    var scope: Scope = .{ .a = a, .shared = &.{}, .warnings = &warnings };
    try scope.services.put(a, "x", .{ .vars = &.{ .{ .name = "A", .value = "${{B}}" }, .{ .name = "B", .value = "${{A}}" } }, .builtins = &.{} });
    try t.expectError(error.ReferenceLoop, scope.all("x"));
}

test "keys follow shell rules" {
    try t.expect(validKey("DATABASE_URL"));
    try t.expect(validKey("_x1"));
    try t.expect(!validKey("1A"));
    try t.expect(!validKey("A-B"));
    try t.expect(!validKey(""));
}
