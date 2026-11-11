const std = @import("std");

const android_targets = [_]struct { abi: []const u8, arch: std.Target.Cpu.Arch }{
    .{ .abi = "arm64-v8a", .arch = .aarch64 },
    .{ .abi = "x86_64", .arch = .x86_64 },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .none },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    b.installArtifact(addExe(b, target, optimize, false));

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/http.zig", "src/routes.zig", "src/store.zig", "src/crypto.zig", "src/vars.zig", "src/detect.zig", "src/github.zig", "src/backup.zig", "src/cron.zig", "src/proxy.zig", "src/tunnel.zig", "src/metrics.zig", "src/httpd.zig", "src/api.zig" }) |file| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const android = b.step("android", "Cross-compile static binaries for Android");
    for (android_targets) |t| {
        const resolved = b.resolveTargetQuery(.{ .cpu_arch = t.arch, .os_tag = .linux, .abi = .none });
        const install = b.addInstallArtifact(addExe(b, resolved, .ReleaseSafe, true), .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("android/{s}", .{t.abi}) } },
        });
        android.dependOn(&install.step);
    }
}

fn addExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "pharbor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    // Newer Android devices run 16 KiB page kernels.
    exe.link_z_max_page_size = 16384;
    return exe;
}
