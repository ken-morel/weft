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
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");

pub const Fetcher = struct {
    deployment: *Deployment,
    remotes: []const Remote,
    lock: std.Io.Mutex = .init,
    pushing: std.StringHashMapUnmanaged(*std.Io.Mutex),
    pulling: std.StringHashMapUnmanaged(*std.Io.Mutex),
    alloc: std.mem.Allocator,
    state: *DeploymentState,
    term: *Term,
    project: *const Project,
    depl: *std.Io.RwLock,
    active_fetches: u32 = 0,

    pub fn deinit(self: *@This()) void {
        var pushing_iter = self.pushing.iterator();
        while (pushing_iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.destroy(entry.value_ptr.*);
        }
        var pulling_iter = self.pulling.iterator();
        while (pulling_iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.pushing.deinit(self.alloc);
        self.pulling.deinit(self.alloc);
    }

    pub fn has_artifact(self: *@This(), io: std.Io, remote: *const Remote, artifact: []const u8) !bool {
        var client = try Client.connect(self.alloc, io, try remote.get_address(), &try remote.get_token());
        defer client.destroy(self.alloc, io);

        const task_id: proto.task.Id = .{
            .deployment = self.deployment.id,
            .pipeline = artifact,
            .workspace = self.deployment.config.workspace,
        };

        const buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
        defer self.alloc.free(buffer);

        try client.conn.send_object(buffer, proto.Request, .artifact_has);
        try client.conn.send_object(buffer, proto.artifact.has.Req, .{ .id = task_id });

        const reply = try client.conn.recv_object(self.alloc, proto.Res(proto.artifact.has.Res));
        const res = try reply;
        return res.has;
    }

    pub fn fetch(self: *@This(), io: std.Io, artifact: []const u8) !void {
        const m = m: {
            try self.lock.lock(io);
            if (self.pulling.get(artifact)) |m| {
                self.lock.unlock(io);
                try m.lock(io);
                break :m m;
            } else {
                const key = try self.alloc.dupe(u8, artifact);
                errdefer self.alloc.free(key);
                const m = try self.alloc.create(std.Io.Mutex);
                m.* = .init;
                m.lockUncancelable(io);
                try self.pulling.put(self.alloc, key, m);
                self.lock.unlock(io);
                break :m m;
            }
        };
        defer m.unlock(io);

        const artifact_path = try self.project.artifact_dir_path(self.alloc, io, self.deployment.id, artifact);
        defer self.alloc.free(artifact_path);

        std.Io.Dir.cwd().access(io, artifact_path, .{}) catch |err| {
            if (err == error.FileNotFound)
                try self.pull_artifact(io, artifact)
            else
                return err;
        };
    }

    pub fn upload(self: *@This(), io: std.Io, remote: *const Remote, artifact: []const u8) !void {
        if (try self.has_artifact(io, remote, artifact)) {
            try self.depl.lock(io);
            defer self.depl.unlock(io);
            self.state.artifact_progress(artifact, remote, .ready, 1.0) catch {};
            return;
        }

        try self.fetch(io, artifact);

        const push_id = try std.mem.join(self.alloc, ".", &.{ remote.get_name(), artifact });
        defer self.alloc.free(push_id);
        const m = m: {
            try self.lock.lock(io);
            if (self.pushing.get(push_id)) |m| {
                self.lock.unlock(io);
                try m.lock(io);
                break :m m;
            } else {
                const key = try self.alloc.dupe(u8, push_id);
                errdefer self.alloc.free(key);
                const m = try self.alloc.create(std.Io.Mutex);
                m.* = .init;
                m.lockUncancelable(io);
                try self.pushing.put(self.alloc, key, m);
                self.lock.unlock(io);
                break :m m;
            }
        };
        defer m.unlock(io);
        if (try self.has_artifact(io, remote, artifact))
            return;
        try self.push_artifact(io, remote, artifact);
    }

    pub inline fn add(self: *@This(), io: std.Io, remote: *const Remote, artifact: []const u8) !void {
        return self.upload(io, remote, artifact);
    }

    pub fn spawn_fetch(self: *@This(), io: std.Io, group: *std.Io.Group, artifact: []const u8) !void {
        {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            self.active_fetches += 1;
        }
        const key = try self.alloc.dupe(u8, artifact);
        errdefer {
            self.lock.lockUncancelable(io);
            self.active_fetches -= 1;
            self.lock.unlock(io);
            self.alloc.free(key);
        }
        spawn(io, group, run_fetch, .{ self, io, key });
    }

    pub fn is_idle(self: *@This(), io: std.Io) bool {
        self.lock.lock(io) catch return true;
        defer self.lock.unlock(io);
        return self.active_fetches == 0;
    }

    pub fn push_artifact(self: *@This(), io: std.Io, remote: *const Remote, artifact: []const u8) !void {
        {
            try self.depl.lock(io);
            defer self.depl.unlock(io);
            try self.state.artifact_progress(artifact, remote, .pushing, 0.0);
        }
        defer if (self.depl.lock(io)) |_| {
            self.state.artifact_progress(artifact, remote, .ready, 1.0) catch {};
            self.depl.unlock(io);
        } else |_| {};

        const read_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
        defer self.alloc.free(read_buffer);
        const send_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
        defer self.alloc.free(send_buffer);
        const compressed_buffer = try self.alloc.alloc(u8, Pressor.chunk_size);
        defer self.alloc.free(compressed_buffer);
        const artifact_dir_path = try self.project.artifact_dir_path(self.alloc, io, self.deployment.id, artifact);
        defer self.alloc.free(artifact_dir_path);

        var client = try Client.connect(self.alloc, io, try remote.get_address(), &try remote.get_token());
        defer client.destroy(self.alloc, io);

        const conn = &client.conn;
        const task_id: proto.task.Id = .{
            .deployment = self.deployment.id,
            .pipeline = artifact,
            .workspace = self.deployment.config.workspace,
        };

        try conn.send_object(send_buffer, proto.Request, .artifact_push);
        try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .header = .{ .id = task_id } });

        const check_res = try conn.recv_object_buf(send_buffer, proto.artifact.push.Res);
        switch (check_res) {
            .has_artifact => |present| if (present) return,
            .footer => {},
        }

        var total_files: u32 = 0;
        {
            var count_dir = try std.Io.Dir.cwd().openDir(io, artifact_dir_path, .{ .iterate = true });
            defer count_dir.close(io);
            var count_walker = try count_dir.walk(self.alloc);
            defer count_walker.deinit();
            while (try count_walker.next(io)) |entry|
                if (entry.kind == .file) {
                    total_files += 1;
                };
        }

        var packer: Packer = try .packer(
            self.alloc,
            try std.Io.Dir.cwd().openDir(
                io,
                artifact_dir_path,
                .{
                    .iterate = true,
                },
            ),
        );
        defer packer.deinit(io);
        const pressor_buffer = try self.alloc.alloc(u8, Pressor.buffer_size);
        defer self.alloc.free(pressor_buffer);
        var pressor: Pressor = .init(pressor_buffer);

        var sent_files: u32 = 0;
        while (try packer.get(io, read_buffer)) |pack| switch (pack) {
            .file => |path| {
                try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .file = path });
                sent_files += 1;
                const pct = if (total_files > 0)
                    @as(f32, @floatFromInt(sent_files)) / @as(f32, @floatFromInt(total_files))
                else
                    1.0;
                {
                    try self.depl.lock(io);
                    defer self.depl.unlock(io);
                    try self.state.artifact_progress(artifact, remote, .pushing, pct);
                }
            },
            .folder => |path| try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .folder = path }),
            .data => |data| {
                var reader: std.Io.Reader = .fixed(data);
                var writer: std.Io.Writer = .fixed(compressed_buffer);
                if (pressor.compress(&reader, &writer)) |_| {
                    if (writer.buffered().len < data.len)
                        try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .data = writer.buffered() })
                    else
                        try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .raw = data });
                } else |err| {
                    if (err != error.WriteFailed)
                        return err;
                    try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .raw = data });
                }
            },
        };
        try conn.send_object(send_buffer, proto.artifact.push.Req, .end);

        const reply = try conn.recv_object_buf(send_buffer, anyerror!proto.artifact.push.Res);
        if (reply) |_| {} else |err| return err;
    }

    pub fn pull_artifact(self: *@This(), io: std.Io, artifact: []const u8) !void {
        const remote: *const Remote = remote: {
            try self.depl.lockShared(io);
            defer self.depl.unlockShared(io);
            for (self.deployment.artifacts) |*art| {
                if (std.mem.eql(u8, art.name, artifact))
                    for (self.remotes) |*rem|
                        if (std.mem.eql(u8, rem.get_name(), art.remote))
                            break :remote rem;
            } else return error.ArtifactNotFound;
        };

        {
            try self.depl.lock(io);
            defer self.depl.unlock(io);
            try self.state.artifact_progress(artifact, remote, .pulling, 0.0);
        }
        defer if (self.depl.lock(io)) |_| {
            self.state.artifact_progress(artifact, remote, .ready, 1.0) catch {};
            self.depl.unlock(io);
        } else |_| {};

        var client = try Client.connect(self.alloc, io, try remote.get_address(), &try remote.get_token());
        defer client.destroy(self.alloc, io);

        const artifact_path = try self.project.artifact_dir_path(self.alloc, io, self.deployment.id, artifact);
        defer self.alloc.free(artifact_path);

        const conn_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
        defer self.alloc.free(conn_buffer);

        const task_id: proto.task.Id = .{
            .deployment = self.deployment.id,
            .pipeline = artifact,
            .workspace = self.deployment.config.workspace,
        };

        try client.conn.send_object(conn_buffer, proto.Request, .artifact_pull);
        try client.conn.send_object(
            conn_buffer,
            proto.artifact.pull.Req,
            .{ .header = .{ .id = task_id } },
        );

        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, artifact_path, .{});

        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        var packer: Packer = .unpacker(dir);
        defer packer.deinit(io);
        const pressor_buffer = try self.alloc.alloc(u8, Pressor.buffer_size);
        defer self.alloc.free(pressor_buffer);
        var pressor: Pressor = .init(pressor_buffer);
        const decompress_buffer = try self.alloc.alloc(u8, Pressor.chunk_size);
        defer self.alloc.free(decompress_buffer);

        var total_files: u32 = 0;
        var received_files: u32 = 0;

        while (true) : (_ = arena.reset(.retain_capacity)) {
            const res = try client.conn.recv_object(arena.allocator(), proto.artifact.pull.Res);
            switch (res) {
                .files => |f| total_files = f,
                .file => |path| {
                    try packer.put(io, .{ .file = path });
                    received_files += 1;
                    const pct = if (total_files > 0)
                        @as(f32, @floatFromInt(received_files)) / @as(f32, @floatFromInt(total_files))
                    else
                        1.0;
                    {
                        try self.depl.lock(io);
                        defer self.depl.unlock(io);
                        try self.state.artifact_progress(artifact, remote, .pulling, pct);
                    }
                },
                .folder => |path| try packer.put(io, .{ .folder = path }),
                .raw => |data| try packer.put(io, .{ .data = data }),
                .compressed => |comp| {
                    var input: std.Io.Reader = .fixed(comp);
                    var output: std.Io.Writer = .fixed(decompress_buffer);
                    try pressor.decompress(&input, &output);
                    try packer.put(io, .{ .data = output.buffered() });
                },
                .end => break,
                .footer => break,
            }
        }
    }
};

pub fn run_fetch(fetcher: *Fetcher, io: std.Io, artifact: []const u8) !void {
    defer {
        fetcher.lock.lockUncancelable(io);
        fetcher.active_fetches -= 1;
        fetcher.lock.unlock(io);
        fetcher.alloc.free(artifact);
    }
    fetcher.fetch(io, artifact) catch |err|
        fetcher.term.err("failed to fetch artifact {s}: {any}", .{ artifact, err });
}

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
        view.finish(io) catch {};
        term.err("Deployment failed... cancelling tasks", .{});
        group.cancel(io);
    }
    while (true) {
        {
            try depl.lock(io);
            defer depl.unlock(io);
            if (deployment.completed() and fetcher.is_idle(io))
                break;

            if (state.has_error() and deployment.running.len == 0)
                return error.DeploymentFailed;

            while (try deployment.next_step()) |step| {
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
    try view.finish(io);
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

    if (!pipeline.script)
        return;

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

    var resolved_pipeline = pipeline.*;
    resolved_pipeline.env = resolved_env;

    var buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(buffer);

    for (pipeline.inputs) |input|
        try fetcher.add(io, remote, input.name);

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
            const script_with_dot = try std.mem.join(alloc, "", &.{ pipeline.name, "." });
            defer alloc.free(script_with_dot);
            const script_dir = project.dir.createDirPathOpen(io, "weft", .{}) catch |err| {
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
                    std.mem.eql(u8, entry.basename, pipeline.name))
                    break :script_path try script_dir.realPathFileAlloc(io, entry.path, alloc);
            } else {
                term.err("script {s} not found", .{pipeline.name});
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
                if (pipeline.outputs.len == 0)
                    try deployment.add_artifact(alloc, step.remote, step.pipeline, "");
                for (pipeline.outputs) |output| {
                    try deployment.add_artifact(alloc, step.remote, step.pipeline, output.name);
                    try fetcher.spawn_fetch(io, group, output.name);
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
