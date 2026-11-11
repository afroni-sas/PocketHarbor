//! One-click services: databases, an S3 bucket and a message broker, each
//! with a volume, a generated password and the variables other services
//! reference to reach it, such as ${{ postgres.DATABASE_URL }}.

const std = @import("std");
const crypto = @import("crypto.zig");
const vars_mod = @import("vars.zig");
const Allocator = std.mem.Allocator;

pub const Template = struct {
    id: []const u8,
    name: []const u8,
    category: []const u8,
    description: []const u8,
    image: []const u8,
    port: u16,
    /// Where its volume is mounted.
    mount: []const u8,
    start_command: []const u8 = "",
    /// `{password}` becomes a generated password, the same everywhere.
    variables: []const [2][]const u8,
    /// The variable other services should reference.
    connect: []const u8,
};

const host = "${{ PHARBOR_PRIVATE_DOMAIN }}";

pub const all = [_]Template{
    .{
        .id = "postgres",
        .name = "PostgreSQL",
        .category = "database",
        .description = "PostgreSQL 16, the relational database most apps start with.",
        .image = "postgres:16-alpine",
        .port = 5432,
        .mount = "/var/lib/postgresql/data",
        .variables = &.{
            .{ "POSTGRES_USER", "postgres" },
            .{ "POSTGRES_PASSWORD", "{password}" },
            .{ "POSTGRES_DB", "app" },
            // The volume's root holds lost+found on some file systems.
            .{ "PGDATA", "/var/lib/postgresql/data/pgdata" },
            .{ "PGHOST", host },
            .{ "PGPORT", "5432" },
            .{ "PGUSER", "${{ POSTGRES_USER }}" },
            .{ "PGPASSWORD", "${{ POSTGRES_PASSWORD }}" },
            .{ "PGDATABASE", "${{ POSTGRES_DB }}" },
            .{ "DATABASE_URL", "postgresql://${{ POSTGRES_USER }}:${{ POSTGRES_PASSWORD }}@" ++ host ++ ":5432/${{ POSTGRES_DB }}" },
        },
        .connect = "DATABASE_URL",
    },
    .{
        .id = "mysql",
        .name = "MySQL",
        .category = "database",
        .description = "MySQL 8.4 LTS.",
        .image = "mysql:8.4",
        .port = 3306,
        .mount = "/var/lib/mysql",
        .variables = &.{
            .{ "MYSQL_ROOT_PASSWORD", "{password}" },
            .{ "MYSQL_DATABASE", "app" },
            .{ "MYSQLHOST", host },
            .{ "MYSQLPORT", "3306" },
            .{ "MYSQLUSER", "root" },
            .{ "MYSQLPASSWORD", "${{ MYSQL_ROOT_PASSWORD }}" },
            .{ "MYSQLDATABASE", "${{ MYSQL_DATABASE }}" },
            .{ "MYSQL_URL", "mysql://root:${{ MYSQL_ROOT_PASSWORD }}@" ++ host ++ ":3306/${{ MYSQL_DATABASE }}" },
        },
        .connect = "MYSQL_URL",
    },
    .{
        .id = "mariadb",
        .name = "MariaDB",
        .category = "database",
        .description = "MariaDB 11, the community fork of MySQL.",
        .image = "mariadb:11",
        .port = 3306,
        .mount = "/var/lib/mysql",
        .variables = &.{
            .{ "MARIADB_ROOT_PASSWORD", "{password}" },
            .{ "MARIADB_DATABASE", "app" },
            .{ "MARIADB_HOST", host },
            .{ "MARIADB_PORT", "3306" },
            .{ "MARIADB_URL", "mysql://root:${{ MARIADB_ROOT_PASSWORD }}@" ++ host ++ ":3306/${{ MARIADB_DATABASE }}" },
        },
        .connect = "MARIADB_URL",
    },
    .{
        .id = "redis",
        .name = "Redis",
        .category = "database",
        .description = "Redis 7 with a password, saving to its volume.",
        .image = "redis:7-alpine",
        .port = 6379,
        .mount = "/data",
        .start_command = "exec redis-server --requirepass \"$REDIS_PASSWORD\" --appendonly yes --dir /data",
        .variables = &.{
            .{ "REDIS_PASSWORD", "{password}" },
            .{ "REDISHOST", host },
            .{ "REDISPORT", "6379" },
            .{ "REDISUSER", "default" },
            .{ "REDIS_URL", "redis://default:${{ REDIS_PASSWORD }}@" ++ host ++ ":6379" },
        },
        .connect = "REDIS_URL",
    },
    .{
        .id = "mongo",
        .name = "MongoDB",
        .category = "database",
        .description = "MongoDB 4.4, the last version that runs on the ARMv8.0 processors of many phones.",
        .image = "mongo:4.4.18",
        .port = 27017,
        .mount = "/data/db",
        .variables = &.{
            .{ "MONGO_INITDB_ROOT_USERNAME", "mongo" },
            .{ "MONGO_INITDB_ROOT_PASSWORD", "{password}" },
            .{ "MONGOHOST", host },
            .{ "MONGOPORT", "27017" },
            .{ "MONGOUSER", "${{ MONGO_INITDB_ROOT_USERNAME }}" },
            .{ "MONGOPASSWORD", "${{ MONGO_INITDB_ROOT_PASSWORD }}" },
            .{ "MONGO_URL", "mongodb://${{ MONGO_INITDB_ROOT_USERNAME }}:${{ MONGO_INITDB_ROOT_PASSWORD }}@" ++ host ++ ":27017" },
        },
        .connect = "MONGO_URL",
    },
    .{
        .id = "minio",
        .name = "MinIO",
        .category = "bucket",
        .description = "S3-compatible object storage. Its console listens on port 9001.",
        .image = "minio/minio:latest",
        .port = 9000,
        .mount = "/data",
        .start_command = "exec minio server /data --console-address :9001",
        .variables = &.{
            .{ "MINIO_ROOT_USER", "minio" },
            .{ "MINIO_ROOT_PASSWORD", "{password}" },
            .{ "S3_ENDPOINT", "http://" ++ host ++ ":9000" },
            .{ "S3_REGION", "us-east-1" },
            .{ "S3_ACCESS_KEY_ID", "${{ MINIO_ROOT_USER }}" },
            .{ "S3_SECRET_ACCESS_KEY", "${{ MINIO_ROOT_PASSWORD }}" },
            .{ "S3_FORCE_PATH_STYLE", "true" },
        },
        .connect = "S3_ENDPOINT",
    },
    .{
        .id = "nats",
        .name = "NATS",
        .category = "other",
        .description = "NATS 2 with JetStream: messaging and queues between services.",
        .image = "nats:2-alpine",
        .port = 4222,
        .mount = "/data",
        .start_command = "exec nats-server -js -sd /data --auth \"$NATS_TOKEN\"",
        .variables = &.{
            .{ "NATS_TOKEN", "{password}" },
            .{ "NATS_URL", "nats://${{ NATS_TOKEN }}@" ++ host ++ ":4222" },
        },
        .connect = "NATS_URL",
    },
};

pub fn find(id: []const u8) ?Template {
    for (all) |tpl| if (std.mem.eql(u8, tpl.id, id)) return tpl;
    return null;
}

/// Letters and digits only, so the password needs no escaping in a URL.
pub fn password(out: []u8) void {
    const alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var raw: [64]u8 = undefined;
    crypto.random(raw[0..out.len]);
    for (out, raw[0..out.len]) |*c, r| c.* = alphabet[r % alphabet.len];
}

/// The template's variables with the password filled in.
pub fn variables(a: Allocator, tpl: Template, secret: []const u8) ![]vars_mod.Var {
    const out = try a.alloc(vars_mod.Var, tpl.variables.len);
    for (tpl.variables, 0..) |kv, i| {
        out[i] = .{ .name = kv[0], .value = try std.mem.replaceOwned(u8, a, kv[1], "{password}", secret) };
    }
    return out;
}

const t = std.testing;

test "every template is complete" {
    for (all) |tpl| {
        try t.expect(tpl.port != 0);
        try t.expect(tpl.mount[0] == '/');
        var found = false;
        var has_password = false;
        for (tpl.variables) |kv| {
            found = found or std.mem.eql(u8, kv[0], tpl.connect);
            has_password = has_password or std.mem.indexOf(u8, kv[1], "{password}") != null;
        }
        try t.expect(found);
        try t.expect(has_password);
    }
    try t.expect(find("postgres") != null);
    try t.expect(find("oracle") == null);
}

test "passwords are filled in" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var secret: [24]u8 = undefined;
    password(&secret);
    for (secret) |c| try t.expect(std.ascii.isAlphanumeric(c));
    const list = try variables(arena.allocator(), find("redis").?, &secret);
    try t.expectEqualStrings(&secret, list[0].value);
    try t.expect(std.mem.indexOf(u8, list[4].value, "${{ REDIS_PASSWORD }}") != null);
}
