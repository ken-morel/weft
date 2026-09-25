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
    deployment_spec: ?[]const u8,
    pipeline_spec: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = project.get_config(alloc, term, io) catch null;
    const workspace = if (config) |c| c.workspace else "";

    const dep_id = if (deployment_spec) |spec| blk: {
        if (std.mem.eql(u8, spec, ".")) {
            break :blk try project.latest_deployment_id(io) orelse {
                term.err("no deployments found in .weft", .{});
                return error.NoDeployments;
            };
        }
        break :blk project.find_deployment_id(io, spec) catch |err| {
            term.err("deployment '{s}' not found: {any}", .{ spec, err });
            return error.InvalidDeploymentId;
        };
    } else try project.latest_deployment_id(io) orelse {
        term.err("no deployments found in .weft", .{});
        return error.NoDeployments;
    };

    const pipe_filter = if (pipeline_spec) |p| blk: {
        if (p.len > 0 and p[0] == '.')
            break :blk p[1..]
        else
            break :blk p;
    } else null;

    var steps_to_kill: std.ArrayList(Step) = .empty;
    defer steps_to_kill.deinit(alloc);

    if (project.load_deployment(alloc, io, dep_id)) |depl| {
        for (depl.targets) |t| {
            if (pipe_filter) |pf| {
                if (!std.mem.eql(u8, t.pipeline, pf)) continue;
            }
            var already = false;
            for (steps_to_kill.items) |s| {
                if (s.eq(t)) {
                    already = true;
                    break;
                }
            }
            if (!already) try steps_to_kill.append(alloc, t);
        }
        for (depl.running) |r| {
            if (pipe_filter) |pf| {
                if (!std.mem.eql(u8, r.pipeline, pf)) continue;
            }
            var already = false;
            for (steps_to_kill.items) |s| {
                if (s.eq(r)) {
                    already = true;
                    break;
                }
            }
            if (!already) try steps_to_kill.append(alloc, r);
        }
    } else |_| {}

    if (steps_to_kill.items.len == 0 and pipe_filter != null) {
        try steps_to_kill.append(alloc, .{
            .remote = "local",
            .pipeline = pipe_filter.?,
        });
    }

    const remotes = inst.get_remotes(alloc, io, term) catch &.{};
    var total_killed: u32 = 0;

    if (steps_to_kill.items.len == 0) {
        const local_count = Task.kill_matching(alloc, io, .{
            .workspace = workspace,
            .deployment = dep_id,
            .pipeline = null,
        }) catch 0;
        total_killed += local_count;
    }

    for (steps_to_kill.items) |step| {
        var killed_count: ?u32 = null;

        const remote = for (remotes) |*r| {
            if (std.mem.eql(u8, r.get_name(), step.remote))
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
                            .pipeline = step.pipeline,
                        })) |_| {
                            if (client.conn.recv_object(alloc, proto.Res(proto.task.kill.Res))) |r_res| {
                                if (r_res) |val| killed_count = val.killed_count else |_| {}
                            } else |_| {}
                        } else |_| {}
                    } else |_| {}
                } else |_| {}
            }
        }

        if (killed_count == null and std.mem.eql(u8, step.remote, "local")) {
            killed_count = Task.kill_matching(alloc, io, .{
                .workspace = workspace,
                .deployment = dep_id,
                .pipeline = step.pipeline,
            }) catch null;
        }

        if (killed_count) |count| {
            total_killed += count;
            if (count > 0) {
                term.println("killed {s}.{s} ({d} task(s))", .{ step.remote, step.pipeline, count });
            }
        } else {
            term.warn("could not reach remote '{s}' for pipeline {s}", .{ step.remote, step.pipeline });
        }
    }

    if (total_killed == 0) {
        term.warn("no matching running tasks found in deployment {s}", .{&dep_id.to_string()});
    }
}
