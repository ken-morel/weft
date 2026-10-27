const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "weft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    b.installArtifact(exe);

    const version_str = @import("build.zig.zon").version;

    const options = b.addOptions();
    options.addOption([]const u8, "version_str", version_str);
    options.addOption([]const u8, "app_id", "cm.engon.weft");
    exe.root_module.addImport("build", options.createModule());

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.addPassthruArgs();
}
