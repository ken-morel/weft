const std = @import("std");

const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const Connection = @import("../wire/Connection.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const DeploymentState = @import("DeploymentState.zig");
const DeploymentView = @import("DeploymentView.zig");
const Fetcher = @import("Fetcher.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");
const runner = @import("runner.zig");
const Step = @import("Step.zig");

fn follow_step(
    alloc: std.mem.Allocator,
    io: std.Io,
    state: *DeploymentState,
    term: *Term,
    view: *DeploymentView,
    project: Project,
    deployment_lock: *std.Io.Mutex,
    deployment: *Deployment,
    remote: *const Remote,
    pipeline: *const Weft.Pipeline,
    fetcher: *Fetcher,
    step: Deployment.Step,
) !void {
    _ = term;
    const task_id: proto.task.Id = .{
        .workspace = deployment.config.workspace,
        .deployment = deployment.id,
        .pipeline = pipeline.name,
    };

    const log_path = try project.task_log_path(alloc, io, deployment.id, step.pipeline);
    defer alloc.free(log_path);

    const log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = false });
    defer log_file.close(io);

    var file_offset = try log_file.length(io);
    var remote_offset: u64 = file_offset;

    const buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(buffer);

    while (true) {
        var client = Client.connect(alloc, io, try remote.get_address(), &try remote.get_token()) catch |e| {
            const err_msg = try std.fmt.allocPrint(alloc, "connection failed: {any}", .{e});
            state.err(io, step.remote, step.pipeline, err_msg);
            break;
        };
        defer client.destroy(alloc, io);

        client.conn.send_object(buffer, proto.Request, .task_poll) catch break;
        client.conn.send_object(buffer, proto.task.poll.Req, .{
            .header = .{
                .task = task_id,
                .logs_offset = remote_offset,
            },
        }) catch break;

        const reply = client.conn.recv_object(alloc, proto.Res(proto.task.poll.Res)) catch break;
        const res = reply catch |e| {
            const err_msg = try std.fmt.allocPrint(alloc, "poll error: {any}", .{e});
            state.err(io, step.remote, step.pipeline, err_msg);
            break;
        };
        const footer = &res.footer;

        if (footer.logs) |logs| {
            if (logs.data.len > 0) {
                try deployment_lock.lock(io);
                const prefix = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ step.remote, step.pipeline });
                defer alloc.free(prefix);
                view.print_logs(prefix, logs.data);
                deployment_lock.unlock(io);

                try log_file.writePositionalAll(io, logs.data, file_offset);
                file_offset += logs.data.len;
            }
            remote_offset = logs.end_offset;
            alloc.free(logs.data);
        }

        if (footer.usage) |u| {
            state.update_usage(io, step.remote, step.pipeline, u.cpu_usec, u.memory_bytes, std.Io.Clock.now(.real, io));
        }

        switch (footer.status) {
            .running => {
                try std.Io.sleep(io, .fromMilliseconds(500), .awake);
                continue;
            },
            .success => {
                try deployment_lock.lock(io);
                defer deployment_lock.unlock(io);

                deployment.remove_running(alloc, step.remote, step.pipeline);

                for (pipeline.outputs()) |output| {
                    try deployment.add_artifact(alloc, .{
                        .remote = step.remote,
                        .pipeline = step.pipeline,
                        .name = output,
                    });
                    try fetcher.spawn_fetch(io, output);
                }

                state.completed(io, step.remote, step.pipeline);
                try deployment.save(alloc, io, project);
                break;
            },
            .failed => |code| {
                try deployment_lock.lock(io);
                defer deployment_lock.unlock(io);

                deployment.remove_running(alloc, step.remote, step.pipeline);
                const err_msg = try std.fmt.allocPrint(alloc, "task failed with exit code {d}", .{code});
                state.err(io, step.remote, step.pipeline, err_msg);
                break;
            },
            .not_found => {
                try deployment_lock.lock(io);
                defer deployment_lock.unlock(io);

                deployment.remove_running(alloc, step.remote, step.pipeline);
                state.err(io, step.remote, step.pipeline, "task not found on daemon");
                break;
            },
        }
    }
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    args: []const []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dep_id: Deployment.Id = undefined;
    var pipeline_filter: ?[]const u8 = null;

    if (args.len == 0) {
        dep_id = try project.latest_deployment_id(io) orelse {
            term.err("no deployments found in .weft", .{});
            return error.NoDeployments;
        };
    } else {
        const first_arg = args[0];
        if (std.mem.startsWith(u8, first_arg, ".")) {
            dep_id = try project.latest_deployment_id(io) orelse {
                term.err("no deployments found in .weft", .{});
                return error.NoDeployments;
            };
            pipeline_filter = first_arg[1..];
        } else if (Deployment.Id.parse(first_arg)) |id| {
            dep_id = id;
            if (args.len > 1) {
                const second = args[1];
                pipeline_filter = if (std.mem.startsWith(u8, second, ".")) second[1..] else second;
            }
        } else |_| {
            dep_id = try project.latest_deployment_id(io) orelse {
                term.err("no deployments found in .weft", .{});
                return error.NoDeployments;
            };
            pipeline_filter = first_arg;
        }
    }

    var deployment = project.load_deployment(alloc, io, dep_id) catch |err| {
        term.err("failed to load deployment: {any}", .{err});
        return err;
    };

    term.info("following deployment {s}", .{&deployment.id.to_string()});

    const remotes = try inst.get_remotes(alloc, io, term);

    var state: DeploymentState = .init(alloc, &project);
    defer state.deinit();
    var depl: std.Io.Mutex = .init;

    var fetcher: Fetcher = .{
        .alloc = alloc,
        .dep = &deployment,
        .depl = &depl,
        .project = &project,
        .remotes = remotes,
        .term = term,
        .state = &state,
    };
    defer fetcher.deinit();

    var steps_list: std.ArrayList(Deployment.Step) = .empty;
    defer steps_list.deinit(alloc);

    if (pipeline_filter) |filter| {
        var found = false;
        for (deployment.targets) |target| {
            if (std.mem.eql(u8, target.pipeline, filter)) {
                try steps_list.append(alloc, target);
                found = true;
                break;
            }
        }
        if (!found) {
            if (deployment.config.get_pipeline(filter)) |_| {
                try steps_list.append(alloc, .{ .remote = "local", .pipeline = filter });
            } else {
                term.err("pipeline '{s}' not found in deployment", .{filter});
                return error.InvalidPipeline;
            }
        }
    } else {
        for (deployment.targets) |target|
            try steps_list.append(alloc, target);
    }

    if (steps_list.items.len == 0) {
        term.err("no targets to follow in deployment", .{});
        return error.NoTargets;
    }

    var group: std.Io.Group = .init;
    errdefer group.cancel(io);

    var view: DeploymentView = .init(alloc, term, &state, deployment.id);
    defer view.deinit();

    for (steps_list.items) |step| {
        const remote: *const Remote = remote: for (remotes) |*rem| {
            if (std.mem.eql(u8, rem.get_name(), step.remote))
                break :remote rem;
        } else {
            term.err("remote '{s}' not found for pipeline '{s}'", .{ step.remote, step.pipeline });
            return error.InvalidRemote;
        };

        const pipeline = deployment.config.get_pipeline(step.pipeline) orelse {
            term.err("pipeline '{s}' not found", .{step.pipeline});
            return error.InvalidPipeline;
        };

        _ = try state.add(io, remote, pipeline);
        state.running(io, step.remote, step.pipeline);

        try spawn(
            io,
            &group,
            follow_step,
            .{ alloc, io, &state, term, &view, project, &depl, &deployment, remote, pipeline, &fetcher, step },
        );
    }

    while (true) {
        {
            try depl.lock(io);
            defer depl.unlock(io);

            var any_running = false;
            for (steps_list.items) |step| {
                if (state.get(io, step.remote, step.pipeline)) |task_state| {
                    if (task_state.status == .running or task_state.status == .preparing) {
                        any_running = true;
                        break;
                    }
                }
            }

            if (!any_running and fetcher.is_idle(io))
                break;

            try view.update(io);
        }
        try std.Io.sleep(io, .fromMilliseconds(250), .awake);
    }

    try group.await(io);
    try view.update(io);
    term.success("follow completed", .{});
}
