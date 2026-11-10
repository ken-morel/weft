const std = @import("std");
const log = std.log.scoped;

const proto = @import("../domain/proto.zig");
const Weft = @import("../domain/Weft.zig");
const Client = @import("Client.zig");
const client_remote = @import("Remote.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");
const Step = @import("Step.zig");

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: Project,
    inst: ClientInstall,
    step: Step,
    deployment_spec: ?[]const u8,
    env: ?*std.process.Environ.Map,
) !void {
    const l = log(.kill);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const needs_resolution = if (deployment_spec) |d|
        d.len != 8
    else
        false;
    const dep_id: Deployment.Id = if (needs_resolution)
        try project.resolve_deployment_id(io, deployment_spec)
    else
        try .parse(deployment_spec orelse unreachable);

    const deployment = project.load_deployment_leaky(gpa, alloc, io, dep_id) catch |err| {
        l.err("failed to load deployment: {any}", .{err});
        return err;
    };

    const remotes = try client_remote.resolve_remotes_leaky(gpa, alloc, io, deployment.config, inst, project);

    const remote_name = if (std.mem.eql(u8, step.group, "_"))
        for (deployment.running) |run_| {
            if (std.mem.eql(u8, run_.pipeline, step.pipeline))
                break run_.group;
        } else for (deployment.artifacts) |art| {
            if (std.mem.eql(u8, art.pipeline, step.pipeline))
                break art.remote;
        } else {
            l.err("Could not find where pipeline {s} did run", .{step.pipeline});
            return error.TaskRemoteNotFound;
        }
    else
        step.group;
    // TODO: Make sure that you error if a remote isn't a group but a remote name

    const remote = for (remotes) |r| {
        if (std.mem.eql(u8, r.name, remote_name))
            break r;
    } else {
        l.err("remote '{s}' not configured", .{remote_name});
        return error.RemoteNotFound;
    };

    var clients: *Client.Manager = try .create(alloc, project, inst.identity, env);
    defer clients.destroy(io);

    const managed = clients.connect(io, remote.address) catch |err| {
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
        .pipeline = step.pipeline,
    });

    _ = try client.conn.recv_object(alloc, proto.Res(proto.task.kill.Res)) catch |err| {
        l.err("remote failed to kill task: {any}", .{err});
        return err;
    };
}
