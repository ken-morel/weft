const std = @import("std");

const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const dotenv_mod = @import("../util/dotenv.zig");
const Connection = @import("../wire/Connection.zig");
const Packer = @import("../wire/Packer.zig");
const Pressor = @import("../wire/Pressor.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const DeploymentState = @import("DeploymentState.zig");
const DeploymentView = @import("DeploymentView.zig");
const Fetcher = @import("Fetcher.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");

pub fn run_deployment(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    deployment: *Deployment,
) !void {
    const remotes = try inst.get_remotes(alloc, io, term);
    defer alloc.free(remotes);

    var dotenv = try dotenv_mod.load(alloc, io, project.dir);
    defer dotenv.deinit(alloc);

    var state: DeploymentState = .init(alloc, &project);
    defer state.deinit();
    var depl: std.Io.RwLock = .init;

    var fetcher: Fetcher = .{
        .alloc = alloc,
        .deployment = deployment,
        .depl = &depl,
        .project = &project,
        .pulling = .empty,
        .pushing = .empty,
        .remotes = remotes,
        .term = term,
        .state = &state,
    };
    defer fetcher.deinit();

    var group: std.Io.Group = .init;
    var view: DeploymentView = .init(alloc, term, &state, deployment.id);
    defer view.deinit();
    errdefer {
        view.update(io) catch {};
        term.err("Deployment failed... cancelling tasks", .{});
        group.cancel(io);
    }
    while (true) {
        {
            try depl.lock(io);
            defer depl.unlock(io);
            if (deployment.completed() and fetcher.is_idle(io))
                break;

            if (state.has_error() and deployment.running.len == 0) {
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

                _ = try state.add(remote, pipeline);
                try deployment.add_running(alloc, step);
                spawn(
                    io,
                    &group,
                    spawn_step,
                    .{ alloc, io, &state, term, project, &depl, deployment, remote, pipeline, &fetcher, step, &dotenv, inst.env, &group },
                );
            }

            try view.update(io);
        }
        try std.Io.sleep(io, .fromMilliseconds(250), .awake);
    }
    try group.await(io);
    try view.update(io);
    term.success("Deployment completed", .{});
}

pub fn spawn_step(
    alloc: std.mem.Allocator,
    io: std.Io,
    state: *DeploymentState,
    term: *Term,
    project: Project,
    deployment_lock: *std.Io.RwLock,
    deployment: *Deployment,
    remote: *const Remote,
    pipeline: *const Weft.Pipeline,
    fetcher: *Fetcher,
    step: Deployment.Step,
    dotenv: *const dotenv_mod.DotEnv,
    env_map: *const std.process.Environ.Map,
    group: *std.Io.Group,
) !void {
    errdefer if (deployment_lock.lock(io)) |_| {
        deployment.remove_running(alloc, step.remote, step.pipeline);
        state.err(step.remote, step.pipeline, "failed to spawn task");
        deployment_lock.unlock(io);
    } else |_| {};

    const script_name = switch (pipeline.run) {
        .nothing => {
            try deployment_lock.lock(io);
            defer deployment_lock.unlock(io);

            for (pipeline.outputs()) |output| {
                try deployment.add_artifact(alloc, .{
                    .remote = step.remote,
                    .pipeline = step.pipeline,
                    .name = output,
                });
                try fetcher.spawn_fetch(io, group, output);
            }
            state.completed(step.remote, step.pipeline);
            try deployment.save(alloc, io, project);
            return;
        },
        .default => pipeline.name,
        .script => |s| s,
    };

    const resolved_env = resolved_env: {
        var merged_env: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer merged_env.deinit(alloc);

        for (deployment.config.env) |entry|
            try merged_env.put(alloc, entry.@"0", entry.@"1");
        for (deployment.config.required_env) |key| {
            if (dotenv.get(key)) |val|
                try merged_env.put(alloc, key, val)
            else if (env_map.get(key)) |val|
                try merged_env.put(alloc, key, val)
            else {
                var found_in_workspace = false;
                for (deployment.config.env) |entry| {
                    if (std.mem.eql(u8, entry.@"0", key)) {
                        found_in_workspace = true;
                        break;
                    }
                }
                if (!found_in_workspace) {
                    term.err("workspace requires environment variable '{s}', but it was not found in .env or environment", .{key});
                    return error.MissingRequiredEnv;
                }
            }
        }

        for (pipeline.required_env) |key| {
            if (dotenv.get(key)) |val|
                try merged_env.put(alloc, key, val)
            else if (env_map.get(key)) |val|
                try merged_env.put(alloc, key, val)
            else {
                var found_in_pipeline = false;
                for (pipeline.env) |entry| {
                    if (std.mem.eql(u8, entry.@"0", key)) {
                        found_in_pipeline = true;
                        break;
                    }
                }
                if (!found_in_pipeline) {
                    term.err("pipeline '{s}' requires environment variable '{s}', but it was not found in .env or environment", .{ pipeline.name, key });
                    return error.MissingRequiredEnv;
                }
            }
        }

        for (pipeline.env) |entry|
            try merged_env.put(alloc, entry.@"0", entry.@"1");

        const resolved_env = try alloc.alloc(struct { []const u8, []const u8 }, merged_env.count());
        defer alloc.free(resolved_env);
        var it = merged_env.iterator();
        var idx: usize = 0;
        while (it.next()) |entry| {
            resolved_env[idx] = .{ entry.key_ptr.*, entry.value_ptr.* };
            idx += 1;
        }
        break :resolved_env resolved_env;
    };

    var resolved_pipeline = pipeline.*;
    resolved_pipeline.env = resolved_env;

    var buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(buffer);

    for (pipeline.inputs()) |input|
        try fetcher.add(io, remote, input);

    const task_id: proto.task.Id = .{
        .deployment = deployment.id,
        .pipeline = pipeline.name,
        .workspace = deployment.config.workspace,
    };

    {
        const client = try Client.connect(alloc, io, try remote.get_address(), &try remote.get_token());
        defer client.destroy(alloc, io);

        try client.conn.send_object(buffer, proto.Request, .task_spawn);
        try client.conn.send_object(buffer, proto.task.spawn.Req, .{
            .task = task_id,
            .pipeline = resolved_pipeline,
        });

        const script_path = script_path: {
            const script_with_dot = try std.mem.join(alloc, "", &.{ script_name, "." });
            defer alloc.free(script_with_dot);
            const script_dir = project.dir.createDirPathOpen(io, "weft", .{ .open_options = .{ .iterate = true } }) catch |err| {
                if (err == error.FileNotFound)
                    term.err("weft folder not found, cannot run pipeline {s}", .{pipeline.name});
                return err;
            };
            defer script_dir.close(io);
            var walker = try std.Io.Dir.walkSelectively(script_dir, alloc);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if ((std.mem.startsWith(u8, entry.basename, script_with_dot) and
                    std.mem.countScalar(u8, entry.basename[script_with_dot.len..], '.') == 0) or
                    std.mem.eql(u8, entry.basename, script_name))
                    break :script_path try script_dir.realPathFileAlloc(io, entry.path, alloc);
            } else {
                term.err("script {s} not found", .{script_name});
                return error.InvalidScript;
            }
        };

        defer alloc.free(script_path);

        const script = project.dir.openFile(io, script_path, .{}) catch |err| {
            if (err == error.FileNotFound)
                term.err("Script {s} does not exist, cannot run pipeline {s}", .{ script_path, pipeline.name });
            return err;
        };
        defer script.close(io);

        while (true) {
            const size = script.readStreaming(io, &.{buffer[1..]}) catch |err|
                if (err == error.EndOfStream)
                    break
                else
                    return err;
            buffer[0] = proto.task.spawn.data;
            try client.conn.send(buffer[0 .. size + 1]);
        }
        buffer[0] = proto.task.spawn.end;
        try client.conn.send(buffer[0..1]);

        _ = client.conn.recv_object_buf(
            buffer,
            proto.Res(proto.task.spawn.Res),
        ) catch |err| {
            try deployment_lock.lock(io);
            defer deployment_lock.unlock(io);
            deployment.remove_running(alloc, step.remote, step.pipeline);
            state.err(step.remote, step.pipeline, @errorName(err));
            return;
        } catch |err| {
            try deployment_lock.lock(io);
            defer deployment_lock.unlock(io);
            deployment.remove_running(alloc, step.remote, step.pipeline);
            const msg = if (err == error.AlreadyRunning)
                "task already running on remote"
            else
                @errorName(err);
            state.err(step.remote, step.pipeline, msg);
            return;
        };
    }

    {
        try deployment_lock.lock(io);
        defer deployment_lock.unlock(io);
        state.running(step.remote, step.pipeline);
    }

    const log_path = try project.task_log_path(alloc, io, deployment.id, step.pipeline);
    defer alloc.free(log_path);

    const log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = false });
    defer log_file.close(io);

    var file_offset = try log_file.length(io);
    var remote_offset: u64 = 0;

    while (true) {
        try std.Io.sleep(io, .fromSeconds(2), .awake);

        const poll_client = try Client.connect(alloc, io, try remote.get_address(), &try remote.get_token());
        defer poll_client.destroy(alloc, io);

        try poll_client.conn.send_object(buffer, proto.Request, .task_poll);
        try poll_client.conn.send_object(buffer, proto.task.poll.Req, .{
            .header = .{
                .task = task_id,
                .logs_offset = remote_offset,
            },
        });

        const res = try try poll_client.conn.recv_object(alloc, proto.Res(proto.task.poll.Res));
        const footer = &res.footer;

        if (footer.logs) |logs| {
            if (logs.data.len > 0) {
                try log_file.writePositionalAll(io, logs.data, file_offset);
                file_offset += logs.data.len;
            }
            remote_offset = logs.end_offset;
            alloc.free(logs.data);
        }

        if (footer.usage) |u| {
            try deployment_lock.lock(io);
            state.update_usage(step.remote, step.pipeline, u.cpu_usec, u.memory_bytes, std.Io.Clock.now(.real, io));
            deployment_lock.unlock(io);
        }

        switch (footer.status) {
            .running => continue,
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
                    try fetcher.spawn_fetch(io, group, output);
                }

                state.completed(step.remote, step.pipeline);
                try deployment.save(alloc, io, project);
                break;
            },
            .failed => |code| {
                try deployment_lock.lock(io);
                defer deployment_lock.unlock(io);

                deployment.remove_running(alloc, step.remote, step.pipeline);
                const err_msg = try std.fmt.allocPrint(alloc, "task failed with exit code {d}", .{code});
                state.err(step.remote, step.pipeline, err_msg);
                break;
            },
            .not_found => {
                try deployment_lock.lock(io);
                defer deployment_lock.unlock(io);

                deployment.remove_running(alloc, step.remote, step.pipeline);
                state.err(step.remote, step.pipeline, "task not found on remote");
                break;
            },
        }
    }
}
