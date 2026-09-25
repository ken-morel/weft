const std = @import("std");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");
const Task = @import("../daemon/Task.zig");
const Term = @import("../domain/Term.zig");
const proto = @import("../domain/proto.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: ?Project,
    inst: ClientInstall,
    pipeline_spec: ?[]const u8,
    deployment_spec: ?[]const u8,
    remote_spec: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (pipeline_spec) |spec| {
        if (Task.from_unit_name(spec)) |unit_task| {
            const rem_name = remote_spec orelse "local";
            try kill_on_remote(alloc, io, term, inst, rem_name, unit_task.id);
            return;
        }
    }

    const prj = project orelse {
        term.err("not in a weft project and no unit name specified", .{});
        return error.NoProject;
    };

    const dep_id = if (deployment_spec) |dep_str|
        prj.find_deployment_id(io, dep_str) catch |err| {
            term.err("deployment '{s}' not found: {any}", .{ dep_str, err });
            return error.InvalidDeploymentId;
        }
    else
        try prj.latest_deployment_id(io) orelse {
            term.err("no deployments found in .weft", .{});
            return error.NoDeployments;
        };

    const deployment = prj.load_deployment(alloc, io, dep_id) catch |err| {
        term.err("failed to load deployment: {any}", .{err});
        return err;
    };

    if (pipeline_spec) |raw_pipe| {
        var pipe_name = raw_pipe;
        var pipe_remote: ?[]const u8 = remote_spec;

        if (std.mem.indexOfScalar(u8, raw_pipe, '.')) |dot_idx| {
            const prefix = raw_pipe[0..dot_idx];
            const remotes = inst.get_remotes(alloc, io, term) catch &.{};
            for (remotes) |*r| {
                if (std.mem.eql(u8, r.get_name(), prefix)) {
                    pipe_remote = prefix;
                    pipe_name = raw_pipe[dot_idx + 1 ..];
                    break;
                }
            }
        }

        const remote_name = pipe_remote orelse for (deployment.targets) |target| {
            if (std.mem.eql(u8, target.pipeline, pipe_name))
                break target.remote;
        } else "local";

        const task_id: proto.task.Id = .{
            .workspace = deployment.config.workspace,
            .deployment = dep_id,
            .pipeline = pipe_name,
        };

        try kill_on_remote(alloc, io, term, inst, remote_name, task_id);
    } else {
        for (deployment.targets) |target| {
            const remote_name = remote_spec orelse target.remote;
            const task_id: proto.task.Id = .{
                .workspace = deployment.config.workspace,
                .deployment = dep_id,
                .pipeline = target.pipeline,
            };
            kill_on_remote(alloc, io, term, inst, remote_name, task_id) catch |err| {
                term.warn("failed to kill {s} on {s}: {any}", .{ target.pipeline, remote_name, err });
            };
        }
    }
}

pub fn kill_on_remote(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    inst: ClientInstall,
    remote_name: []const u8,
    task_id: proto.task.Id,
) !void {
    if (std.mem.eql(u8, remote_name, "local")) {
        const t: Task = .{ .id = task_id };
        const active = t.is_active(alloc, io) catch false;
        if (active) {
            try t.kill(alloc, io);
            term.println("killed task {s} on local", .{task_id.pipeline});
        } else {
            term.warn("task {s} was not running on local", .{task_id.pipeline});
        }
        return;
    }

    const remotes = try inst.get_remotes(alloc, io, term);
    const remote = for (remotes) |*r| {
        if (std.mem.eql(u8, r.get_name(), remote_name))
            break r;
    } else {
        term.err("remote '{s}' not found", .{remote_name});
        return error.RemoteNotFound;
    };

    var client = try Client.connect(alloc, io, try remote.get_address(), &try remote.get_token());
    defer client.destroy(alloc, io);

    var send_buf: [256]u8 = undefined;
    try client.conn.send_object(&send_buf, proto.Request, .task_kill);
    try client.conn.send_object(&send_buf, proto.task.kill.Req, .{ .task = task_id });

    const res = try try client.conn.recv_object(alloc, proto.Res(proto.task.kill.Res));
    if (res.killed) {
        term.println("killed task {s} on {s}", .{ task_id.pipeline, remote_name });
    } else {
        term.warn("task {s} was not running on {s}", .{ task_id.pipeline, remote_name });
    }
}
