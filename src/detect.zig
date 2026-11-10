//! Works out how to build a repository that has no Dockerfile, and writes one.
//! What it guesses is shown in the build log, and the build and start
//! commands of a service override it.

const std = @import("std");
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

pub const Plan = struct {
    language: []const u8,
    dockerfile: []const u8,
    /// The port the result listens on when it is not $PORT.
    port: u16 = 0,
};

pub const Overrides = struct {
    build_command: []const u8 = "",
    start_command: []const u8 = "",
};

const Dir = struct {
    a: Allocator,
    root: []const u8,

    fn path(self: Dir, rel: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, rel }) catch @panic("OOM");
    }

    fn has(self: Dir, rel: []const u8) bool {
        var p = sys.Path.of(self.path(rel)) catch return false;
        return sys.exists(p.z());
    }

    fn read(self: Dir, rel: []const u8) []const u8 {
        return sys.readFileAlloc(self.a, self.path(rel), 1 << 20) catch "";
    }

    fn contains(self: Dir, rel: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.read(rel), needle) != null;
    }
};

/// Quotes a command for `CMD ["sh", "-c", ...]`.
fn shellCmd(a: Allocator, cmd: []const u8) ![]const u8 {
    const quoted = try std.json.Stringify.valueAlloc(a, cmd, .{});
    return std.fmt.allocPrint(a, "CMD [\"sh\", \"-c\", {s}]\n", .{quoted});
}

/// The `web:` line of a Procfile, the convention of Heroku-style apps.
fn procfileWeb(d: Dir) ?[]const u8 {
    const text = d.read("Procfile");
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, l, "web:")) return std.mem.trim(u8, l[4..], " ");
    }
    return null;
}

pub fn detect(a: Allocator, root: []const u8, o: Overrides) !?Plan {
    const d: Dir = .{ .a = a, .root = root };
    if (d.has("package.json")) return try node(d, o);
    if (d.has("requirements.txt") or d.has("pyproject.toml") or d.has("Pipfile")) return try python(d, o);
    if (d.has("go.mod")) return try golang(d, o);
    if (d.has("Cargo.toml")) return try rust(d, o);
    if (d.has("composer.json") or d.has("index.php")) return try php(d, o);
    if (d.has("Gemfile")) return try ruby(d, o);
    if (d.has("pom.xml") or d.has("build.gradle") or d.has("build.gradle.kts")) return try java(d, o);
    if (d.has("deno.json") or d.has("deno.jsonc")) return try deno(d, o);
    if (d.has("index.html")) return try staticSite(a, "COPY . /usr/share/nginx/html\n", "static");
    return null;
}

const nginx_spa =
    \\FROM nginx:alpine
    \\RUN printf 'server {\n  listen 80;\n  root /usr/share/nginx/html;\n  location / { try_files $uri $uri/ /index.html; }\n}\n' > /etc/nginx/conf.d/default.conf
    \\
;

fn staticSite(a: Allocator, copy: []const u8, language: []const u8) !Plan {
    return .{ .language = language, .dockerfile = try std.mem.concat(a, u8, &.{ nginx_spa, copy }), .port = 80 };
}

fn node(d: Dir, o: Overrides) !Plan {
    const a = d.a;
    const pkg_text = d.read("package.json");
    const Pkg = struct {
        scripts: ?std.json.ArrayHashMap([]const u8) = null,
        engines: ?struct { node: ?[]const u8 = null } = null,
        dependencies: ?std.json.ArrayHashMap([]const u8) = null,
        devDependencies: ?std.json.ArrayHashMap([]const u8) = null,
        main: ?[]const u8 = null,
    };
    const pkg = std.json.parseFromSliceLeaky(Pkg, a, pkg_text, .{ .ignore_unknown_fields = true }) catch Pkg{};
    const has_script = struct {
        fn f(p: Pkg, name: []const u8) bool {
            const s = p.scripts orelse return false;
            return s.map.contains(name);
        }
    }.f;
    const depends = struct {
        fn f(p: Pkg, name: []const u8) bool {
            if (p.dependencies) |m| if (m.map.contains(name)) return true;
            if (p.devDependencies) |m| if (m.map.contains(name)) return true;
            return false;
        }
    }.f;

    // The major version from "engines": ">=20", "20.x", "^22.1".
    var version: []const u8 = "22";
    if (pkg.engines) |e| if (e.node) |v| {
        var i: usize = 0;
        while (i < v.len and !std.ascii.isDigit(v[i])) i += 1;
        var j = i;
        while (j < v.len and std.ascii.isDigit(v[j])) j += 1;
        if (j > i) version = v[i..j];
    };

    const Pm = struct { image: []const u8, setup: []const u8, install: []const u8, run: []const u8, lock: []const u8 };
    const pm: Pm = if (d.has("bun.lockb") or d.has("bun.lock"))
        .{ .image = "oven/bun:1-alpine", .setup = "", .install = "bun install", .run = "bun run", .lock = if (d.has("bun.lock")) "bun.lock" else "bun.lockb" }
    else if (d.has("pnpm-lock.yaml"))
        .{ .image = "", .setup = "RUN corepack enable\n", .install = "pnpm install --frozen-lockfile", .run = "pnpm run", .lock = "pnpm-lock.yaml" }
    else if (d.has("yarn.lock"))
        .{ .image = "", .setup = "RUN corepack enable\n", .install = "yarn install --frozen-lockfile", .run = "yarn", .lock = "yarn.lock" }
    else if (d.has("package-lock.json"))
        .{ .image = "", .setup = "", .install = "npm ci", .run = "npm run", .lock = "package-lock.json" }
    else
        .{ .image = "", .setup = "", .install = "npm install", .run = "npm run", .lock = "" };
    const image = if (pm.image.len > 0) pm.image else try std.fmt.allocPrint(a, "node:{s}-alpine", .{version});

    var df: std.ArrayList(u8) = .empty;
    try df.print(a, "FROM {s} AS build\nWORKDIR /app\n{s}COPY package.json {s} ./\nRUN {s}\nCOPY . .\n", .{ image, pm.setup, pm.lock, pm.install });
    const build = if (o.build_command.len > 0)
        o.build_command
    else if (has_script(pkg, "build"))
        try std.fmt.allocPrint(a, "{s} build", .{pm.run})
    else
        "";
    if (build.len > 0) try df.print(a, "RUN {s}\n", .{build});

    var start: []const u8 = o.start_command;
    if (start.len == 0) start = procfileWeb(d) orelse "";
    if (start.len == 0 and has_script(pkg, "start")) start = try std.fmt.allocPrint(a, "{s} start", .{pm.run});
    if (start.len == 0) if (pkg.main) |m| {
        start = try std.fmt.allocPrint(a, "node {s}", .{m});
    };
    if (start.len == 0 and build.len > 0) {
        // A front end with nothing to run: serve what the build produced.
        const out_dir = if (depends(pkg, "react-scripts")) "build" else "dist";
        try df.print(a, "\n{s}COPY --from=build /app/{s} /usr/share/nginx/html\n", .{ nginx_spa, out_dir });
        return .{ .language = "node (static)", .dockerfile = df.items, .port = 80 };
    }
    if (start.len == 0) {
        for ([_][]const u8{ "server.js", "index.js", "app.js", "main.js" }) |f| {
            if (d.has(f)) {
                start = try std.fmt.allocPrint(a, "node {s}", .{f});
                break;
            }
        }
    }
    if (start.len == 0) return error.NoStartCommand;
    try df.appendSlice(a, "ENV NODE_ENV=production\n");
    try df.appendSlice(a, try shellCmd(a, start));
    return .{ .language = "node", .dockerfile = df.items };
}

fn python(d: Dir, o: Overrides) !Plan {
    const a = d.a;
    var df: std.ArrayList(u8) = .empty;
    try df.appendSlice(a, "FROM python:3.12-slim\nWORKDIR /app\nENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1\n");
    if (d.has("requirements.txt")) {
        try df.appendSlice(a, "COPY requirements.txt ./\nRUN pip install -r requirements.txt\nCOPY . .\n");
    } else if (d.has("pyproject.toml")) {
        try df.appendSlice(a, "COPY . .\nRUN pip install .\n");
    } else {
        try df.appendSlice(a, "COPY . .\nRUN pip install pipenv && pipenv install --system --deploy\n");
    }
    if (o.build_command.len > 0) try df.print(a, "RUN {s}\n", .{o.build_command});

    const reqs = try std.mem.concat(a, u8, &.{ d.read("requirements.txt"), d.read("pyproject.toml"), d.read("Pipfile") });
    const has_dep = struct {
        fn f(text: []const u8, name: []const u8) bool {
            var i: usize = 0;
            while (i + name.len <= text.len) : (i += 1) {
                if (std.ascii.eqlIgnoreCase(text[i..][0..name.len], name)) return true;
            }
            return false;
        }
    }.f;
    var start: []const u8 = o.start_command;
    if (start.len == 0) start = procfileWeb(d) orelse "";
    if (start.len == 0 and d.has("manage.py")) {
        const project = djangoProject(d) orelse "";
        start = if (project.len > 0 and has_dep(reqs, "gunicorn"))
            try std.fmt.allocPrint(a, "python manage.py migrate --noinput && gunicorn {s}.wsgi --bind 0.0.0.0:$PORT", .{project})
        else
            "python manage.py migrate --noinput && python manage.py runserver 0.0.0.0:$PORT";
    }
    if (start.len == 0) {
        for ([_][]const u8{ "main", "app", "server" }) |m| {
            const file = try std.fmt.allocPrint(a, "{s}.py", .{m});
            if (!d.has(file)) continue;
            if (d.contains(file, "FastAPI(") and has_dep(reqs, "uvicorn")) {
                start = try std.fmt.allocPrint(a, "uvicorn {s}:app --host 0.0.0.0 --port $PORT", .{m});
            } else if (d.contains(file, "Flask(") and has_dep(reqs, "gunicorn")) {
                start = try std.fmt.allocPrint(a, "gunicorn {s}:app --bind 0.0.0.0:$PORT", .{m});
            } else if (d.contains(file, "Flask(")) {
                start = try std.fmt.allocPrint(a, "flask --app {s} run --host 0.0.0.0 --port $PORT", .{m});
            } else {
                start = try std.fmt.allocPrint(a, "python {s}", .{file});
            }
            break;
        }
    }
    if (start.len == 0) return error.NoStartCommand;
    try df.appendSlice(a, try shellCmd(a, start));
    return .{ .language = "python", .dockerfile = df.items };
}

/// The Django project: the package whose settings manage.py points at.
fn djangoProject(d: Dir) ?[]const u8 {
    const text = d.read("manage.py");
    const key = "DJANGO_SETTINGS_MODULE\", \"";
    const i = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[i + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    return rest[0..end];
}

fn golang(d: Dir, o: Overrides) !Plan {
    const a = d.a;
    // "go 1.22" or "go 1.22.3" in go.mod.
    var version: []const u8 = "1.23";
    var lines = std.mem.splitScalar(u8, d.read("go.mod"), '\n');
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, l, "go ")) continue;
        const v = std.mem.trim(u8, l[3..], " ");
        var dots: usize = 0;
        var end: usize = v.len;
        for (v, 0..) |ch, i| {
            if (ch == '.') {
                dots += 1;
                if (dots == 2) {
                    end = i;
                    break;
                }
            }
        }
        version = v[0..end];
    }
    var pkg: []const u8 = ".";
    if (!d.has("main.go") and d.has("cmd")) {
        var p = try sys.Path.of(d.path("cmd"));
        var it = sys.DirIter.open_(p.z()) catch null;
        if (it) |*dir| {
            defer dir.deinit();
            if (dir.next() catch null) |ent| pkg = try std.fmt.allocPrint(a, "./cmd/{s}", .{ent.name});
        }
    }
    const build = if (o.build_command.len > 0) o.build_command else try std.fmt.allocPrint(a, "CGO_ENABLED=0 go build -o /out/app {s}", .{pkg});
    var df: std.ArrayList(u8) = .empty;
    try df.print(a, "FROM golang:{s}-alpine AS build\nWORKDIR /src\nCOPY . .\nRUN mkdir -p /out && {s}\n\nFROM alpine:3.20\nRUN apk add --no-cache ca-certificates tzdata\nCOPY --from=build /out /out\n", .{ version, build });
    try df.appendSlice(a, if (o.start_command.len > 0) try shellCmd(a, o.start_command) else "CMD [\"/out/app\"]\n");
    return .{ .language = "go", .dockerfile = df.items };
}

fn rust(d: Dir, o: Overrides) !Plan {
    const a = d.a;
    var name: []const u8 = "app";
    var lines = std.mem.splitScalar(u8, d.read("Cargo.toml"), '\n');
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, l, "name")) continue;
        const q1 = std.mem.indexOfScalar(u8, l, '"') orelse continue;
        const q2 = std.mem.indexOfScalarPos(u8, l, q1 + 1, '"') orelse continue;
        name = l[q1 + 1 .. q2];
        break;
    }
    const build = if (o.build_command.len > 0) o.build_command else "cargo build --release";
    var df: std.ArrayList(u8) = .empty;
    try df.print(a, "FROM rust:1-slim AS build\nWORKDIR /src\nCOPY . .\nRUN {s} && mkdir -p /out && cp target/release/{s} /out/app\n\nFROM debian:bookworm-slim\nRUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*\nCOPY --from=build /out /out\n", .{ build, name });
    try df.appendSlice(a, if (o.start_command.len > 0) try shellCmd(a, o.start_command) else "CMD [\"/out/app\"]\n");
    return .{ .language = "rust", .dockerfile = df.items };
}

fn php(d: Dir, o: Overrides) !Plan {
    const a = d.a;
    var df: std.ArrayList(u8) = .empty;
    try df.appendSlice(a, "FROM php:8.3-cli-alpine\nWORKDIR /app\nCOPY . .\n");
    if (d.has("composer.json")) {
        try df.appendSlice(a, "COPY --from=composer:2 /usr/bin/composer /usr/bin/composer\nRUN composer install --no-dev --optimize-autoloader --no-interaction\n");
    }
    if (o.build_command.len > 0) try df.print(a, "RUN {s}\n", .{o.build_command});
    const docroot = if (d.has("public")) "public" else ".";
    const start = if (o.start_command.len > 0) o.start_command else procfileWeb(d) orelse try std.fmt.allocPrint(a, "php -S 0.0.0.0:$PORT -t {s}", .{docroot});
    try df.appendSlice(a, try shellCmd(a, start));
    return .{ .language = "php", .dockerfile = df.items };
}

fn ruby(d: Dir, o: Overrides) !Plan {
    const a = d.a;
    var df: std.ArrayList(u8) = .empty;
    try df.appendSlice(a, "FROM ruby:3.3-alpine\nRUN apk add --no-cache build-base tzdata\nWORKDIR /app\nCOPY Gemfile* ./\nRUN bundle install\nCOPY . .\n");
    if (o.build_command.len > 0) try df.print(a, "RUN {s}\n", .{o.build_command});
    var start: []const u8 = o.start_command;
    if (start.len == 0) start = procfileWeb(d) orelse "";
    if (start.len == 0 and d.has("config/application.rb")) start = "bundle exec rails server -b 0.0.0.0 -p $PORT";
    if (start.len == 0 and d.has("config.ru")) start = "bundle exec rackup -o 0.0.0.0 -p $PORT";
    if (start.len == 0) return error.NoStartCommand;
    try df.appendSlice(a, try shellCmd(a, start));
    return .{ .language = "ruby", .dockerfile = df.items };
}

fn java(d: Dir, o: Overrides) !Plan {
    const a = d.a;
    const maven = d.has("pom.xml");
    const build = if (o.build_command.len > 0)
        o.build_command
    else if (maven)
        "mvn -q -DskipTests package && cp $(ls target/*.jar | grep -v original | head -n 1) /out/app.jar"
    else
        "gradle build -x test --no-daemon && cp $(ls build/libs/*.jar | grep -v plain | head -n 1) /out/app.jar";
    var df: std.ArrayList(u8) = .empty;
    try df.print(a, "FROM {s} AS build\nWORKDIR /src\nCOPY . .\nRUN mkdir -p /out && {s}\n\nFROM eclipse-temurin:21-jre-alpine\nCOPY --from=build /out /out\n", .{
        if (maven) "maven:3-eclipse-temurin-21" else "gradle:8-jdk21",
        build,
    });
    try df.appendSlice(a, try shellCmd(a, if (o.start_command.len > 0) o.start_command else "java -jar /out/app.jar"));
    return .{ .language = "java", .dockerfile = df.items };
}

fn deno(d: Dir, o: Overrides) !Plan {
    const a = d.a;
    var entry: []const u8 = "main.ts";
    for ([_][]const u8{ "main.ts", "server.ts", "mod.ts", "main.js" }) |f| {
        if (d.has(f)) {
            entry = f;
            break;
        }
    }
    var df: std.ArrayList(u8) = .empty;
    try df.print(a, "FROM denoland/deno:alpine\nWORKDIR /app\nCOPY . .\nRUN deno cache {s}\n", .{entry});
    if (o.build_command.len > 0) try df.print(a, "RUN {s}\n", .{o.build_command});
    const start = if (o.start_command.len > 0) o.start_command else try std.fmt.allocPrint(a, "deno run -A {s}", .{entry});
    try df.appendSlice(a, try shellCmd(a, start));
    return .{ .language = "deno", .dockerfile = df.items };
}

const t = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    dir: []const u8,

    fn init(files: []const [2][]const u8) !Fixture {
        var f: Fixture = .{ .arena = std.heap.ArenaAllocator.init(t.allocator), .dir = "" };
        var id: [12]u8 = undefined;
        sys.randomId(&id);
        f.dir = try std.fmt.allocPrint(f.arena.allocator(), "/tmp/pd-detect-{s}", .{id});
        for (files) |file| {
            const p = try std.fmt.allocPrint(f.arena.allocator(), "{s}/{s}", .{ f.dir, file[0] });
            try sys.mkdirP(std.fs.path.dirname(p).?, 0o700);
            try sys.writeFile(p, file[1], 0o600);
        }
        return f;
    }

    fn deinit(f: *Fixture) void {
        sys.rmrf(f.dir) catch {};
        f.arena.deinit();
    }

    fn plan(f: *Fixture, o: Overrides) !Plan {
        return (try detect(f.arena.allocator(), f.dir, o)).?;
    }
};

test "node with npm, a build and a start script" {
    var f = try Fixture.init(&.{
        .{ "package.json", "{\"engines\":{\"node\":\">=20.0\"},\"scripts\":{\"build\":\"tsc\",\"start\":\"node dist/index.js\"}}" },
        .{ "package-lock.json", "{}" },
    });
    defer f.deinit();
    const p = try f.plan(.{});
    try t.expectEqualStrings("node", p.language);
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "FROM node:20-alpine") != null);
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "RUN npm ci") != null);
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "RUN npm run build") != null);
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "\"npm run start\"") != null);
}

test "a front end without a server is served by nginx" {
    var f = try Fixture.init(&.{
        .{ "package.json", "{\"scripts\":{\"build\":\"vite build\"},\"devDependencies\":{\"vite\":\"5\"}}" },
        .{ "pnpm-lock.yaml", "" },
    });
    defer f.deinit();
    const p = try f.plan(.{});
    try t.expectEqual(@as(u16, 80), p.port);
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "pnpm install --frozen-lockfile") != null);
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "COPY --from=build /app/dist") != null);
}

test "overrides win over what is detected" {
    var f = try Fixture.init(&.{.{ "package.json", "{\"scripts\":{\"start\":\"node a.js\"}}" }});
    defer f.deinit();
    const p = try f.plan(.{ .build_command = "make assets", .start_command = "node b.js --port \"$PORT\"" });
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "RUN make assets") != null);
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "\"node b.js --port \\\"$PORT\\\"\"") != null);
}

test "python apps find their server" {
    var f = try Fixture.init(&.{
        .{ "requirements.txt", "fastapi\nuvicorn[standard]\n" },
        .{ "main.py", "from fastapi import FastAPI\napp = FastAPI()\n" },
    });
    defer f.deinit();
    const p = try f.plan(.{});
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "uvicorn main:app --host 0.0.0.0 --port $PORT") != null);
}

test "a Procfile names the start command" {
    var f = try Fixture.init(&.{
        .{ "requirements.txt", "gunicorn\n" },
        .{ "Procfile", "release: python migrate.py\nweb: gunicorn shop.wsgi --bind 0.0.0.0:$PORT\n" },
    });
    defer f.deinit();
    const p = try f.plan(.{});
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "gunicorn shop.wsgi") != null);
}

test "go uses the version from go.mod and builds statically" {
    var f = try Fixture.init(&.{
        .{ "go.mod", "module x\n\ngo 1.22.3\n" },
        .{ "cmd/server/main.go", "package main" },
    });
    defer f.deinit();
    const p = try f.plan(.{});
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "FROM golang:1.22-alpine") != null);
    try t.expect(std.mem.indexOf(u8, p.dockerfile, "go build -o /out/app ./cmd/server") != null);
}

test "a plain site is static" {
    var f = try Fixture.init(&.{.{ "index.html", "<h1>hi</h1>" }});
    defer f.deinit();
    const p = try f.plan(.{});
    try t.expectEqualStrings("static", p.language);
    try t.expectEqual(@as(u16, 80), p.port);
}

test "nothing recognisable" {
    var f = try Fixture.init(&.{.{ "README.md", "hello" }});
    defer f.deinit();
    try t.expect(try detect(f.arena.allocator(), f.dir, .{}) == null);
}
