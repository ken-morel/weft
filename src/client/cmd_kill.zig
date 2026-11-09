const std = @import("std");
const log = std.log.scoped;

const proto = @import("../domain/proto.zig");
const Weft = @import("../domain/Weft.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Step = @import("Step.zig");

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: Project,
    inst: *const ClientInstall,
    step: Step,
    deployment_spec: ?[]const u8,
    env: ?*std.process.Environ.Map,
) !void {
    const l = log(.kill);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const dep_id = try project.resolve_deployment_id(io, deployment_spec);

    var deployment = project.load_deployment_leaky(gpa, alloc, io, dep_id) catch |err| {
        l.err("failed to load deployment: {any}", .{err});
        return err;
    };

    const remotes = try deployment.config.remotes_with_local_leaky(alloc);

    const pipeline_name = step.pipeline;
    const pipeline = deployment.config.get_pipeline(pipeline_name) orelse {
        l.err("pipeline '{s}' not found in deployment {s}", .{ pipeline_name, &deployment.id.to_string() });
        return error.InvalidPipeline;
    };

    const remote_name = if (std.mem.eql(u8, step.remote, "_"))
        for (deployment.running) |run_| {
            if (std.mem.eql(u8, run_.pipeline, pipeline_name))
                break run_.remote;
        } else for (deployment.artifacts) |art| {
            if (std.mem.eql(u8, art.pipeline, pipeline_name))
                break art.remote;
        } else deployment.config.select_remote_for(pipeline, null) orelse "local"
    else
        step.remote;

    const remote = for (remotes) |*r| {
        if (std.mem.eql(u8, r.@"0", remote_name))
            break r;
    } else {
        l.err("remote '{s}' not configured", .{remote_name});
        return error.RemoteNotFound;
    };

    var clients: *Client.Manager = try .create(alloc, project, inst.identity, env);
    defer clients.destroy(io);

    const managed = clients.connect_str(io, remote.@"1") catch |err| {
        l.err("could not reach remote '{s}': {any}", .{ remote_name, err });
        return err;
    };
    defer managed.release(io);
    const client = managed.inner;

    var send_buf: [256]u8 = undefined;
    _ = try client.conn.send_object(&send_buf, proto.Request, .task_kill);
    _ = try client.conn.send_object(&send_buf, proto.task.kill.Req, .{
        .workspace = deployment.config.workspace,
        .deployment = dep_id,
        .pipeline = pipeline_name,
    });

    _ = try client.conn.recv_object(alloc, proto.Res(proto.task.kill.Res)) catch |err| {
        l.err("remote failed to kill task: {any}", .{err});
        return err;
    };
}
