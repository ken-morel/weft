const std = @import("std");
const log = std.log.scoped;

const Term = @import("../domain/Term.zig");
const ClientInstall = @import("ClientInstall.zig");
const Project = @import("Project.zig");
const runner = @import("runner.zig");

pub fn spawn(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: *const ClientInstall,
    pipeline_name: []const u8,
    remote_spec: ?[]const u8,
    deployment_spec: ?[]const u8,
) !void {
    const l = log(.spawn);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = try project.get_config_leaky(alloc, io);
    const pipeline = config.get_pipeline(pipeline_name) orelse {
        l.err("pipeline '{s}' not found", .{pipeline_name});
        return error.InvalidPipeline;
    };

    const remote_name: []const u8 = if (remote_spec) |name| remote_name: {
        const remote = config.find_remote(name) orelse {
            l.err("remote '{s}' not found", .{name});
            return error.InvalidRemote;
        };
        if (!pipeline.matches_remote(remote)) {
            l.err("pipeline '{s}' cannot run on remote '{s}' (does not match .on)", .{ pipeline_name, name });
            return error.InvalidRemote;
        }
        break :remote_name remote.@"0";
    } else for (try config.remotes_with_local_leaky(alloc)) |remote| {
        if (pipeline.matches_remote(remote))
            break remote.@"0";
    } else {
        l.err("no remote matches pipeline '{s}' (.on)", .{pipeline_name});
        return error.NoMatchingRemote;
    };

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

    var deployment = try project.load_deployment_leaky(alloc, io, dep_id);
    deployment.config = config;

    return runner.run_task(gpa, io, term, project, inst, &deployment, .{
        .mode = "default",
        .remote = remote_name,
        .pipeline = pipeline_name,
    });
}
