const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_model = .baseline,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version_str", @import("build.zig.zon").version);
    options.addOption([]const u8, "app_id", "cm.engon.weft");

    const weft = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = (optimize != .debug),
        .imports = &.{
            .{ .name = "build", .module = options.createModule() },
        },
    });

    const exe = b.addExecutable(.{
        .name = "weft",
        .root_module = weft,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.addPassthruArgs();
}
