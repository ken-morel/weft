const std = @import("std");

const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const dotenv = @import("../util/dotenv.zig");
const Connection = @import("../wire/Connection.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const DeploymentState = @import("DeploymentState.zig");
const DeploymentView = @import("DeploymentView.zig");
const Fetcher = @import("Fetcher.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");

pub fn run_deployment(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    deployment: *Deployment,
) !void {
    const remotes = try inst.get_remotes(gpa, io, term);
    defer gpa.free(remotes);

    var env = try dotenv.load(gpa, io, project.dir);
    defer env.deinit(gpa);

    var state: DeploymentState = .init(gpa, &project);
    defer state.deinit();
    var depl: std.Io.Mutex = .init;

    var fetcher: Fetcher = .{
        .alloc = gpa,
        .dep = deployment,
        .depl = &depl,
        .project = &project,
        .remotes = remotes,
        .term = term,
        .state = &state,
    };
    defer fetcher.deinit();

    var group: std.Io.Group = .init;
    var view: DeploymentView = .init(gpa, term, &state, deployment.id);
    defer view.deinit();
    errdefer {
        view.update(io) catch {};
        term.err("Deployment failed... cancelling tasks", .{});
        group.cancel(io);
    }

    const log_buffer = try gpa.alloc(u8, 32 << 10);
    defer gpa.free(log_buffer);

    var poll_arena = std.heap.ArenaAllocator.init(gpa);
    defer poll_arena.deinit();

    while (true) : (try std.Io.sleep(io, .fromMilliseconds(250), .awake)) {
        try depl.lock(io);
        defer depl.unlock(io);
        if (deployment.completed() and fetcher.is_idle(io))
            break;

        if (state.has_error(io) and deployment.running.len == 0) {
            try deployment.save(gpa, io, project);
            term.err("Error during deployment", .{});
            try std.Io.sleep(io, .fromSeconds(3), .awake);
            try view.update(io);
            return error.DeploymentFailed;
        }

        while (try deployment.next_step(term)) |step| {
            const remote: *const Remote = remote: for (remotes) |*remote| {
                if (std.mem.eql(u8, remote.get_name(), step.remote))
                    break :remote remote;
            } else return error.InvalidRemote;

            const pipeline = deployment.config.get_pipeline(step.pipeline) orelse
                return error.InvalidPipeline;

            try spawn(
                io,
                &group,
                spawn_step,
                .{ gpa, io, &state, term, project, &depl, deployment, remote, pipeline, &fetcher, step, &env, inst.env },
            );
        }

        for (deployment.running) |step| {
            const step_state = state.get(io, step.remote, step.pipeline) orelse continue;
            if (step_state.status != .running) continue;

            const remote: *const Remote = remote: for (remotes) |*r| {
                if (std.mem.eql(u8, r.get_name(), step.remote))
                    break :remote r;
            } else continue;

            const task_id: proto.task.Id = .{
                .deployment = deployment.id,
                .pipeline = step.pipeline,
                .workspace = deployment.config.workspace,
            };

            const addr = remote.get_address() catch continue;
            const token = remote.get_token() catch continue;
            var poll_client = Client.connect(gpa, io, addr, &token) catch continue;
            defer poll_client.destroy(gpa, io);

            poll_client.conn.send_object(log_buffer, proto.Request, .task_poll) catch continue;
            poll_client.conn.send_object(log_buffer, proto.task.poll.Req, .{
                .header = .{
                    .task = task_id,
                    .logs_offset = step_state.log_offset,
                },
            }) catch continue;

            const res = poll_client.conn.recv_object(poll_arena.allocator(), proto.Res(proto.task.poll.Res)) catch continue;
            if (res) |r| {
                const footer = &r.footer;

                if (footer.logs) |logs| {
                    if (logs.data.len > 0) {
                        const prefix = try std.fmt.allocPrint(poll_arena.allocator(), "{s}.{s}", .{ step.remote, step.pipeline });
                        view.print_logs(prefix, logs.data);
                    }
                    state.set_log_offset(io, step.remote, step.pipeline, logs.end_offset);
                }

                if (footer.usage) |u| {
                    state.update_usage(io, step.remote, step.pipeline, u.cpu_usec, u.memory_bytes, std.Io.Clock.now(.real, io));
                }

                switch (footer.status) {
                    .running => {},
                    .success => {
                        deployment.remove_running(gpa, step.remote, step.pipeline);
                        const pipeline = deployment.config.get_pipeline(step.pipeline);
                        if (pipeline) |p| {
                            for (p.outputs()) |output| {
                                try deployment.add_artifact(gpa, .{
                                    .remote = step.remote,
                                    .pipeline = step.pipeline,
                                    .name = output,
                                });
                                try fetcher.spawn_fetch(io, output);
                            }
                        }

                        state.completed(io, step.remote, step.pipeline);
                        try deployment.save(gpa, io, project);
                    },
                    .failed => |code| {
                        deployment.remove_running(gpa, step.remote, step.pipeline);
                        deployment.add_failed(gpa, step) catch {};
                        const err_msg = try std.fmt.allocPrint(gpa, "task failed with exit code {d}", .{code});
                        state.err(io, step.remote, step.pipeline, err_msg);
                        deployment.save(gpa, io, project) catch {};
                    },
                    .not_found => {
                        deployment.remove_running(gpa, step.remote, step.pipeline);
                        deployment.add_failed(gpa, step) catch {};
                        state.err(io, step.remote, step.pipeline, "task not found on remote");
                        deployment.save(gpa, io, project) catch {};
                    },
                }
            } else |_| {}

            _ = poll_arena.reset(.retain_capacity);
        }

        try view.update(io);
    }
    try group.await(io);
    try view.update(io);
    term.success("Deployment completed", .{});
}

pub fn spawn_step(
    gpa: std.mem.Allocator,
    io: std.Io,
    state: *DeploymentState,
    term: *Term,
    project: Project,
    depl: *std.Io.Mutex,
    dep: *Deployment,
    remote: *const Remote,
    pipeline: *const Weft.Pipeline,
    fetcher: *Fetcher,
    step: Deployment.Step,
    env: *const dotenv.DotEnv,
    env_map: *const std.process.Environ.Map,
) !void {
    errdefer if (depl.lock(io)) |_| {
        dep.remove_running(gpa, step.remote, step.pipeline);
        dep.add_failed(gpa, step) catch {};
        state.err(io, step.remote, step.pipeline, "failed to spawn task");
        dep.save(gpa, io, project) catch {};
        depl.unlock(io);
    } else |_| {};

    const script_name = switch (pipeline.run) {
        .nothing => {
            try depl.lock(io);
            defer depl.unlock(io);

            for (pipeline.outputs()) |output| {
                try dep.add_artifact(gpa, .{
                    .remote = step.remote,
                    .pipeline = step.pipeline,
                    .name = output,
                });
                try fetcher.spawn_fetch(io, output);
            }
            dep.remove_running(gpa, step.remote, step.pipeline);
            state.completed(io, step.remote, step.pipeline);
            try dep.save(gpa, io, project);
            return;
        },
        .default => pipeline.name,
        .script => |s| s,
    };

    const resolved_env = resolved_env: {
        var merged_env: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer merged_env.deinit(gpa);

        for (dep.config.env) |entry|
            try merged_env.put(gpa, entry.@"0", entry.@"1");
        for (dep.config.required_env) |key| {
            if (env.get(key)) |val|
                try merged_env.put(gpa, key, val)
            else if (env_map.get(key)) |val|
                try merged_env.put(gpa, key, val)
            else {
                var found_in_workspace = false;
                for (dep.config.env) |entry| {
                    if (std.mem.eql(u8, entry.@"0", key)) {
                        found_in_workspace = true;
                        break;
                    }
                }
                if (!found_in_workspace) {
                    term.err("Required env var '{s}' not found in environment or .env file for pipeline {s}", .{ key, pipeline.name });
                    return error.MissingRequiredEnv;
                }
            }
        }
        for (pipeline.env) |entry|
            try merged_env.put(gpa, entry.@"0", entry.@"1");
        for (pipeline.required_env) |key| {
            if (env.get(key)) |val|
                try merged_env.put(gpa, key, val)
            else if (env_map.get(key)) |val|
                try merged_env.put(gpa, key, val)
            else {
                var found_in_pipeline = false;
                for (pipeline.env) |entry| {
                    if (std.mem.eql(u8, entry.@"0", key)) {
                        found_in_pipeline = true;
                        break;
                    }
                }
                if (!found_in_pipeline) {
                    term.err("Required env var '{s}' not found in environment or .env file for pipeline {s}", .{ key, pipeline.name });
                    return error.MissingRequiredEnv;
                }
            }
        }

        var result: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
        var iter = merged_env.iterator();
        while (iter.next()) |entry|
            try result.append(gpa, .{ entry.key_ptr.*, entry.value_ptr.* });
        break :resolved_env result;
    };

    var resolved_pipeline = pipeline.*;
    resolved_pipeline.env = resolved_env.items;

    const task_id: proto.task.Id = .{
        .deployment = dep.id,
        .pipeline = step.pipeline,
        .workspace = dep.config.workspace,
    };
    _ = try state.add(io, remote, pipeline);

    for (pipeline.inputs()) |input|
        try fetcher.upload(io, remote, input);

    const buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(buffer);

    spawn_task: {
        const client = try Client.connect(gpa, io, try remote.get_address(), &try remote.get_token());
        defer client.destroy(gpa, io);

        try client.conn.send_object(buffer, proto.Request, .task_spawn);
        try client.conn.send_object(buffer, proto.task.spawn.Req, .{
            .task = task_id,
            .pipeline = resolved_pipeline,
        });

        const script_path = try project.locate_script(gpa, io, script_name) orelse {
            term.err("weft folder not found, cannot run pipeline {s}", .{pipeline.name});
            return error.FileNotFound;
        };

        defer gpa.free(script_path);

        upload_script: {
            const script = project.dir.openFile(io, script_path, .{}) catch |err| {
                if (err == error.FileNotFound)
                    term.err("Script {s} does not exist, cannot run pipeline {s}", .{ script_path, pipeline.name });
                return err;
            };
            defer script.close(io);

            @memcpy(buffer[0..4], "pack");

            while (true) {
                const size = script.readStreaming(io, &.{buffer[5..]}) catch |err|
                    if (err == error.EndOfStream)
                        break
                    else
                        return err;
                buffer[4] = proto.data;
                try client.conn.send(buffer[0 .. 5 + size]);
            }
            buffer[4] = proto.end;
            try client.conn.send(buffer[0..5]);
            break :upload_script;
        }

        const res = client.conn.recv_object_buf(
            buffer,
            proto.Res(proto.task.spawn.Res),
        ) catch |err| {
            try depl.lock(io);
            defer depl.unlock(io);
            dep.remove_running(gpa, step.remote, step.pipeline);
            dep.add_failed(gpa, step) catch {};
            state.err(io, step.remote, step.pipeline, @errorName(err));
            dep.save(gpa, io, project) catch {};
            return;
        };

        if (res) |_| {
            try depl.lock(io);
            try dep.add_running(gpa, step);
            state.running(io, step.remote, step.pipeline);
            defer depl.unlock(io);
        } else |err| {
            try depl.lock(io);
            defer depl.unlock(io);
            dep.remove_running(gpa, step.remote, step.pipeline);
            dep.add_failed(gpa, step) catch {};
            const msg = if (err == error.AlreadyRunning)
                "task already running on remote"
            else
                @errorName(err);
            state.err(io, step.remote, step.pipeline, msg);
            dep.save(gpa, io, project) catch {};
            return;
        }
        break :spawn_task;
    }
}
