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

    var remote_name = remote_spec orelse "local";
    var pipe_filter: ?[]const u8 = null;
    var dep_id: ?Deployment.Id = null;
    var workspace: []const u8 = "";

    if (pipeline_spec) |raw_pipe| {
        if (Task.from_unit_name(raw_pipe)) |unit_task| {
            workspace = unit_task.id.workspace;
            dep_id = unit_task.id.deployment;
            pipe_filter = unit_task.id.pipeline;
        } else {
            var raw = raw_pipe;
            if (std.mem.indexOfScalar(u8, raw, '.')) |dot_idx| {
                const prefix = raw[0..dot_idx];
                const remotes = inst.get_remotes(alloc, io, term) catch &.{};
                for (remotes) |*r| {
                    if (std.mem.eql(u8, r.get_name(), prefix)) {
                        remote_name = prefix;
                        raw = raw[dot_idx + 1 ..];
                        break;
                    }
                }
            }
            if (!std.mem.eql(u8, raw, ".")) {
                pipe_filter = raw;
            }
        }
    }

    if (project) |prj| {
        if (workspace.len == 0) {
            const config = prj.get_config(alloc, term, io) catch null;
            if (config) |c| workspace = c.workspace;
        }

        if (dep_id == null) {
            if (deployment_spec) |dep_str| {
                if (!std.mem.eql(u8, dep_str, ".")) {
                    dep_id = prj.find_deployment_id(io, dep_str) catch |err| {
                        term.err("deployment '{s}' not found: {any}", .{ dep_str, err });
                        return error.InvalidDeploymentId;
                    };
                }
            } else {
                dep_id = prj.latest_deployment_id(io) catch null;
            }
        }
    } else {
        if (deployment_spec) |dep_str| {
            if (!std.mem.eql(u8, dep_str, ".")) {
                dep_id = Deployment.Id.parse(dep_str) catch |err| {
                    term.err("invalid deployment id '{s}': {any}", .{ dep_str, err });
                    return err;
                };
            }
        }
    }

    var killed_count: ?u32 = null;

    const remotes = inst.get_remotes(alloc, io, term) catch &.{};
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
