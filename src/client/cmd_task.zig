const std = @import("std");
const log = std.log.scoped;

const Term = @import("../domain/Term.zig");
const ClientInstall = @import("ClientInstall.zig");
const Project = @import("Project.zig");
const runner = @import("runner.zig");
const Step = @import("Step.zig");

pub fn spawn(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: *const ClientInstall,
    step: Step,
    deployment_spec: ?[]const u8,
) !void {
    const l = log(.spawn);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = try project.get_config_leaky(alloc, io);

    const dep_id = if (deployment_spec) |dep_str|
        project.find_deployment_id(io, dep_str) catch |err| {
            l.err("deployment '{s}' not found or ambiguous: {any}", .{ dep_str, err });
            return error.InvalidDeploymentId;
        }
    else
        try project.latest_deployment_id(io) orelse {
            l.err("no deployments found in .weft", .{});
            return error.NoDeployments;
        };

    var deployment = try project.load_deployment_leaky(alloc, gpa, io, dep_id);
    deployment.config = config;

    return runner.run_task(gpa, io, term, project, inst, &deployment, step);
}
