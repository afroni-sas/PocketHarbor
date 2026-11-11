//! The Data tab of a database: what it holds and a console for queries. It
//! runs the database's own client inside its container with `pdock exec`,
//! so the credentials stay in the container's environment and nothing is
//! linked into PocketHarbor. The query goes in on stdin, never in a shell
//! command line.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { postgres, mysql, redis, mongo };

pub fn kindOf(image: []const u8) ?Kind {
    var buf: [256]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..@min(image.len, buf.len)], image[0..@min(image.len, buf.len)]);
    // The repository name, without registry, owner or tag.
    const tail = lower[(std.mem.lastIndexOfScalar(u8, lower, '/') orelse return kindOfName(lower)) + 1 ..];
    return kindOfName(tail);
}

fn kindOfName(name: []const u8) ?Kind {
    const repo = name[0 .. std.mem.indexOfAny(u8, name, ":@") orelse name.len];
    if (std.mem.startsWith(u8, repo, "postgres") or std.mem.eql(u8, repo, "postgis") or std.mem.startsWith(u8, repo, "timescaledb")) return .postgres;
    if (std.mem.eql(u8, repo, "mysql") or std.mem.eql(u8, repo, "mariadb")) return .mysql;
    if (std.mem.startsWith(u8, repo, "redis") or std.mem.eql(u8, repo, "valkey")) return .redis;
    if (std.mem.eql(u8, repo, "mongo")) return .mongo;
    return null;
}

const postgres_env =
    \\export PGOPTIONS='-c client_min_messages=warning'
    \\U="${POSTGRES_USER:-postgres}"
    \\D="${POSTGRES_DB:-$U}"
    \\
;

const mysql_env =
    \\export MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
    \\D="${MARIADB_DATABASE:-${MYSQL_DATABASE:-}}"
    \\C="$(command -v mariadb || command -v mysql)"
    \\
;

const redis_env =
    \\[ -n "${REDIS_PASSWORD:-}" ] && export REDISCLI_AUTH="$REDIS_PASSWORD"
    \\
;

const mongo_env =
    \\M="$(command -v mongosh || command -v mongo)"
    \\set -- --quiet
    \\[ -n "${MONGO_INITDB_ROOT_USERNAME:-}" ] && set -- "$@" -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin
    \\
;

/// Prints one item per line: its name, a tab or comma, and how many rows
/// or documents it has (-1 when unknown). Keys have no count. PostgreSQL
/// counts exactly up to about 100,000 rows and estimates past that.
pub fn listScript(kind: Kind) []const u8 {
    return switch (kind) {
        .postgres => postgres_env ++
            \\exec psql -X -q -U "$U" -d "$D" --csv -t -c "select n.nspname || '.' || c.relname, case when c.relkind in ('r', 'p') and c.reltuples < 100000 then (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', n.nspname, c.relname), false, true, '')))[1]::text::bigint else c.reltuples::bigint end from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r', 'p', 'v', 'm') and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_toast%' order by 1"
        ,
        .mysql => mysql_env ++
            \\exec "$C" -uroot --batch --skip-column-names -e "select table_name, coalesce(table_rows, -1) from information_schema.tables where table_schema = database() order by 1" "$D"
        ,
        .redis => redis_env ++
            \\redis-cli --scan --count 1000 | head -n 1000
        ,
        .mongo => mongo_env ++
            \\exec "$M" "$@" --eval 'db.adminCommand({listDatabases: 1}).databases.forEach(function (d) { if (["admin", "config", "local"].indexOf(d.name) < 0) db.getSiblingDB(d.name).getCollectionNames().forEach(function (c) { print(d.name + "." + c + "\t" + db.getSiblingDB(d.name).getCollection(c).estimatedDocumentCount()) }) })'
        ,
    };
}

/// Runs what arrives on stdin: SQL, Redis commands or shell JavaScript.
pub fn queryScript(kind: Kind) []const u8 {
    return switch (kind) {
        .postgres => postgres_env ++
            \\exec psql -X -q -U "$U" -d "$D" --csv -v ON_ERROR_STOP=1 -f -
        ,
        .mysql => mysql_env ++
            \\exec "$C" -uroot --batch "$D"
        ,
        .redis => redis_env ++
            \\exec redis-cli --no-raw
        ,
        .mongo => mongo_env ++
            \\exec "$M" "$@"
        ,
    };
}

pub const Item = struct { name: []const u8, rows: ?i64 };

/// The output of `listScript`.
pub fn parseList(a: Allocator, kind: Kind, text: []const u8) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (kind == .redis) {
            try out.append(a, .{ .name = line, .rows = null });
            continue;
        }
        const sep = std.mem.lastIndexOfAny(u8, line, if (kind == .postgres) "," else "\t") orelse continue;
        var name = line[0..sep];
        // CSV quotes a name that holds a comma or a quote.
        if (kind == .postgres and name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') {
            name = try std.mem.replaceOwned(u8, a, name[1 .. name.len - 1], "\"\"", "\"");
        }
        const count = std.fmt.parseInt(i64, std.mem.trim(u8, line[sep + 1 ..], " "), 10) catch null;
        try out.append(a, .{ .name = name, .rows = if (count) |c| (if (c < 0) null else c) else null });
    }
    return out.items;
}

const t = std.testing;

test "kinds from images" {
    try t.expectEqual(Kind.postgres, kindOf("postgres:16-alpine").?);
    try t.expectEqual(Kind.postgres, kindOf("docker.io/library/postgres").?);
    try t.expectEqual(Kind.postgres, kindOf("postgis/postgis:16-3.4").?);
    try t.expectEqual(Kind.mysql, kindOf("mariadb:11").?);
    try t.expectEqual(Kind.mysql, kindOf("MySQL:8.4").?);
    try t.expectEqual(Kind.redis, kindOf("redis:7-alpine").?);
    try t.expectEqual(Kind.mongo, kindOf("mongo:4.4.18").?);
    try t.expect(kindOf("nginx:alpine") == null);
    try t.expect(kindOf("ghcr.io/me/mongo-express") == null);
}

test "lists" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pg = try parseList(a, .postgres, "public.users,12\n\"public.odd,name\"\"x\",-1\n");
    try t.expectEqual(@as(usize, 2), pg.len);
    try t.expectEqualStrings("public.users", pg[0].name);
    try t.expectEqual(@as(?i64, 12), pg[0].rows);
    try t.expectEqualStrings("public.odd,name\"x", pg[1].name);
    try t.expectEqual(@as(?i64, null), pg[1].rows);
    const my = try parseList(a, .mysql, "orders\t3\n");
    try t.expectEqualStrings("orders", my[0].name);
    const keys = try parseList(a, .redis, "a key\nb\n");
    try t.expectEqualStrings("a key", keys[0].name);
    try t.expectEqual(@as(?i64, null), keys[0].rows);
}
