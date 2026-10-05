const std = @import("std");
const log = std.log.scoped;

const proto = @import("../domain/proto.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: Project,
    inst: ClientInstall,
    pipeline: []const u8,
    remote_name: []const u8,
    deployment_spec: []const u8,
) !void {
    const l = log(.kill);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = try project.get_config_leaky(alloc, io);

    const dep_id = if (deployment_spec.len == 8)
        try Deployment.Id.parse(deployment_spec)
    else
        project.find_deployment_id(io, deployment_spec) catch |err| {
            l.err("deployment '{s}' not found: {any}", .{ deployment_spec, err });
            return;
        };

    const remotes = inst.get_remotes_leaky(alloc, io) catch &.{};
    const remote = for (remotes) |*r| {
        if (std.mem.eql(u8, r.get_name(), remote_name)) break r;
    } else {
        l.err("remote '{s}' not configured", .{remote_name});
        return error.RemoteNotFound;
    };

    const addr = (remote.get_address() catch null) orelse return error.InvalidRemoteConfig;
    const tok = (remote.get_token() catch null) orelse return error.InvalidRemoteConfig;

    const client = Client.connect(alloc, io, addr, &tok) catch |err| {
        l.err("could not reach remote '{s}': {any}", .{ remote_name, err });
        return err;
    };
    defer client.destroy(alloc, io);

    var send_buf: [256]u8 = undefined;
    _ = try client.conn.send_object(&send_buf, proto.Request, .task_kill);
    _ = try client.conn.send_object(&send_buf, proto.task.kill.Req, .{
        .workspace = config.workspace,
        .deployment = dep_id,
        .pipeline = pipeline,
    });

    _ = try client.conn.recv_object(alloc, proto.Res(proto.task.kill.Res)) catch |err| {
        l.err("remote failed to kill task: {any}", .{err});
        return;
    };
}
