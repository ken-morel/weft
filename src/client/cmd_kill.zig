const std = @import("std");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");
const Step = @import("Step.zig");
const Task = @import("../daemon/Task.zig");
const Term = @import("../domain/Term.zig");
const proto = @import("../domain/proto.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    step: Step,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = project.get_config(alloc, term, io) catch null;
    const workspace = if (config) |c| c.workspace else "";

    const dep_id = if (std.mem.eql(u8, step.remote, "local"))
        try project.latest_deployment_id(io) orelse {
            term.err("no deployments found in .weft", .{});
            return error.NoDeployments;
        }
    else
        project.find_deployment_id(io, step.remote) catch |err| {
            term.err("deployment '{s}' not found: {any}", .{ step.remote, err });
            return error.InvalidDeploymentId;
        };

    var pipe_filter: []const u8 = step.pipeline;
    var remote_name: []const u8 = "local";

    const remotes = inst.get_remotes(alloc, io, term) catch &.{};

    if (Task.from_unit_name(step.pipeline)) |unit_task| {
        pipe_filter = unit_task.id.pipeline;
    } else if (std.mem.indexOfScalar(u8, step.pipeline, '.')) |dot_idx| {
        const prefix = step.pipeline[0..dot_idx];
        for (remotes) |*r| {
            if (std.mem.eql(u8, r.get_name(), prefix)) {
                remote_name = prefix;
                pipe_filter = step.pipeline[dot_idx + 1 ..];
                break;
            }
        }
    }

    if (std.mem.eql(u8, remote_name, "local")) {
        if (project.load_deployment(alloc, io, dep_id)) |depl| {
            for (depl.targets) |t| {
                if (std.mem.eql(u8, t.pipeline, pipe_filter)) {
                    remote_name = t.remote;
                    break;
                }
            } else for (depl.running) |r| {
                if (std.mem.eql(u8, r.pipeline, pipe_filter)) {
                    remote_name = r.remote;
                    break;
                }
            }
        } else |_| {}
    }

    var killed_count: ?u32 = null;

    const remote = for (remotes) |*r| {
        if (std.mem.eql(u8, r.get_name(), remote_name))
            break r;
    } else null;

    if (remote) |r| {
        const addr = r.get_address() catch null;
        const tok = r.get_token() catch null;
        if (addr != null and tok != null) {
            if (Client.connect(alloc, io, addr.?, &tok.?)) |client| {
                defer client.destroy(alloc, io);

                var send_buf: [256]u8 = undefined;
                if (client.conn.send_object(&send_buf, proto.Request, .task_kill)) |_| {
                    if (client.conn.send_object(&send_buf, proto.task.kill.Req, .{
                        .workspace = workspace,
                        .deployment = dep_id,
                        .pipeline = pipe_filter,
                    })) |_| {
                        if (client.conn.recv_object(alloc, proto.Res(proto.task.kill.Res))) |r_res| {
                            if (r_res) |val| killed_count = val.killed_count else |_| {}
                        } else |_| {}
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        }
    }

    if (killed_count == null and std.mem.eql(u8, remote_name, "local")) {
        killed_count = Task.kill_matching(alloc, io, .{
            .workspace = workspace,
            .deployment = dep_id,
            .pipeline = pipe_filter,
        }) catch |err| {
            term.err("kill failed: {any}", .{err});
            return err;
        };
    }

    if (killed_count) |count| {
        if (count > 0) {
            term.println("killed {d} task(s) on {s}", .{ count, remote_name });
        } else {
            term.warn("no matching running tasks found on {s}", .{remote_name});
        }
    } else {
        term.err("could not connect to remote '{s}'", .{remote_name});
        return error.ConnectionFailed;
    }
}
