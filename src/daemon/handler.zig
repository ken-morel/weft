const std = @import("std");

const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const systemd = @import("../util/systemd.zig");
const zoto = @import("../util/zoto.zig");
const Connection = @import("../wire/Connection.zig");
const Packer = @import("../wire/Packer.zig");
const Pressor = @import("../wire/Pressor.zig");
const Daemon = @import("Daemon.zig");
const DaemonInstall = @import("DaemonInstall.zig");
const Server = @import("Server.zig");
const Task = @import("Task.zig");

pub fn handle(daemon: *Daemon, permits: *std.Io.Semaphore, stream: std.Io.net.Stream) !void {
    defer permits.post(daemon.io);

    _run(daemon, stream) catch |err| {
        if (err == error.ReAssigned)
            return;
        daemon.term.err("worker error: {any}", .{err});
        if (@errorReturnTrace()) |trace|
            std.debug.dumpErrorReturnTrace(trace);
    };

    stream.close(daemon.io);
}

fn _run(daemon: *Daemon, stream: std.Io.net.Stream) !void {
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const reader_buf = try gpa.alloc(u8, 4 << 10);
    defer gpa.free(reader_buf);
    const writer_buf = try gpa.alloc(u8, 4 << 10);
    defer gpa.free(writer_buf);

    var reader = stream.reader(daemon.io, reader_buf);
    var writer = stream.writer(daemon.io, writer_buf);

    var conn: Connection = try .init(
        daemon.io,
        &try daemon.config.get_secret(),
        &reader.interface,
        &writer.interface,
    );

    const request = request: {
        var req_buffer: [1 << 5]u8 = undefined;
        break :request conn.recv_object_buf(&req_buffer, proto.Request) catch |err|
            return if (err == error.BufferTooSmall)
                error.InvalidRequest
            else
                err;
    };

    daemon.term.info("Request: {any}", .{request});

    const response_buf = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(response_buf);
    switch (request) {
        .artifact_push => {
            const res = handle_artifact_push(daemon, &arena, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                daemon.term.err("daemon::worker::artifact_push {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .task_spawn => {
            const res = handle_task_spawn(daemon, &arena, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                daemon.term.err("daemon::worker::task_spawn {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .artifact_pull => {
            const res = handle_artifact_pull(daemon, &arena, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                daemon.term.err("daemon::worker::artifact_pull {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .task_poll => {
            const res = handle_task_poll(daemon, &arena, &conn, response_buf) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                daemon.term.err("daemon::worker::task_poll {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .artifact_has => {
            const res = handle_artifact_has(daemon, &arena, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                daemon.term.err("daemon::worker::artifact_has {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .system_stats => {
            const req = try conn.recv_object_buf(response_buf, proto.system.stats.Req);
            try daemon.stats_server.add_listener(stream, req.from);
            return error.ReAssigned;
        },
    }
}

fn handle_artifact_has(daemon: *Daemon, arena: *std.heap.ArenaAllocator, conn: *Connection) proto.Res(proto.artifact.has.Res) {
    const ara = arena.allocator();
    const gpa = daemon.gpa;
    const io = daemon.io;

    const req = try conn.recv_object(ara, proto.artifact.has.Req);
    const deployment = req.id.deployment.to_string();
    const artifact_dir_path = try paths.artifact(
        gpa,
        req.id.workspace,
        &deployment,
        req.id.pipeline,
    );
    defer gpa.free(artifact_dir_path);
    const has = has: {
        std.Io.Dir.cwd().access(
            io,
            artifact_dir_path,
            .{},
        ) catch |err|
            if (err == error.FileNotFound)
                break :has false
            else
                return err;
        break :has true;
    };
    return .{ .has = has };
}

fn handle_artifact_pull(daemon: *Daemon, arena: *std.heap.ArenaAllocator, conn: *Connection) proto.Res(proto.artifact.pull.Res) {
    const gpa = daemon.gpa;
    const io = daemon.io;
    const ara = arena.allocator();
    const req = try conn.recv_object(ara, proto.artifact.pull.Req);
    const id = &req.header.id;
    const deployment = id.deployment.to_string();

    const artifact_dir = artifact_dir: {
        const artifact_dir_path = try paths.artifact(
            gpa,
            id.workspace,
            &deployment,
            id.pipeline,
        );
        defer gpa.free(artifact_dir_path);
        break :artifact_dir std.Io.Dir.cwd().openDir(
            io,
            artifact_dir_path,
            .{ .iterate = true },
        ) catch |err|
            return if (err == error.FileNotFound)
                error.ArtifactNotFound
            else
                err;
    };
    defer artifact_dir.close(io);

    const file_count = file_count: {
        var walker = try artifact_dir.walk(gpa);
        var count: u32 = 0;
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .file) {
                count += 1;
            }
        }
        break :file_count count;
    };

    send_files: {
        var packer: Packer = try .packer(gpa, artifact_dir);
        defer packer.deinit(io);
        const buffer = try gpa.alloc(u8, Pressor.chunk_size + 5);
        defer gpa.free(buffer);

        try conn.send_object(buffer, proto.artifact.pull.Res, .{ .files = file_count });

        while (try packer.get(io, buffer[5..])) |pack| {
            @memcpy(buffer[0..4], "pack");
            switch (pack) {
                .file => |path| {
                    buffer[4] = proto.file;
                    @memcpy(buffer[5 .. 5 + path.len], path);
                    try conn.send(buffer[0 .. 5 + path.len]);
                },
                .folder => |path| {
                    buffer[4] = proto.folder;
                    @memcpy(buffer[5 .. 5 + path.len], path);
                    try conn.send(buffer[0 .. 5 + path.len]);
                },
                .data => |data| if (try daemon.pressor.try_acquire()) |pressor| {
                    defer pressor.release();
                    var reader: std.Io.Reader = .fixed(data);
                    if (pressor.compress(&reader)) |compressed| {
                        if (compressed.len < data.len) {
                            buffer[4] = proto.compressed_data;
                            @memcpy(buffer[5 .. 5 + compressed.len], compressed);
                            try conn.send(buffer[0 .. 5 + compressed.len]);
                        } else {
                            buffer[4] = proto.data;
                            try conn.send(buffer[0 .. 5 + data.len]);
                        }
                    } else |_| {
                        buffer[4] = proto.data;
                        try conn.send(buffer[0 .. 5 + data.len]);
                    }
                } else {
                    buffer[4] = proto.data;
                    try conn.send(buffer[0 .. 5 + data.len]);
                },
            }
        }

        @memcpy(buffer[0..4], "pack");
        buffer[4] = proto.end;
        try conn.send(buffer[0..5]);
        break :send_files;
    }

    return .{ .footer = .{} };
}

fn handle_artifact_push(daemon: *Daemon, arena: *std.heap.ArenaAllocator, conn: *Connection) proto.Res(proto.artifact.push.Res) {
    const ara = arena.allocator();
    const gpa = daemon.gpa;
    const io = daemon.io;
    var buf: [32]u8 = undefined;
    const req = switch (try conn.recv_object(ara, proto.artifact.push.Req)) {
        .header => |h| h,
        else => return error.ExpectedHeader,
    };
    const deployment = req.id.deployment.to_string();

    const artifact_dir_path = try paths.artifact(
        gpa,
        req.id.workspace,
        &deployment,
        req.id.pipeline,
    );
    defer gpa.free(artifact_dir_path);

    const has_artifact = has_artifact: {
        std.Io.Dir.cwd().access(
            io,
            artifact_dir_path,
            .{},
        ) catch |err|
            if (err == error.FileNotFound)
                break :has_artifact false
            else
                return err;
        break :has_artifact true;
    };
    try conn.send_object(&buf, proto.artifact.push.Res, .{ .has_artifact = has_artifact });
    if (has_artifact)
        return .{ .footer = .{} };

    const temp_dir_path = receive_artifacts: {
        var temp_dir = try daemon.install.open_temp(io, "artifact");
        defer temp_dir.close(io);

        var packer: Packer = .unpacker(temp_dir);
        defer packer.deinit(io);

        var step_arena: std.heap.ArenaAllocator = .init(gpa);
        defer step_arena.deinit();
        while (true) : (_ = step_arena.reset(.retain_capacity)) {
            const raw = try conn.recv_object(step_arena.allocator(), proto.artifact.push.Req);
            switch (raw) {
                .folder => |path| {
                    try packer.put(io, .{ .folder = path });
                },
                .file => |path| {
                    try packer.put(io, .{ .file = path });
                },
                .raw => |data| {
                    try packer.put(io, .{ .data = data });
                },
                .data => |data| {
                    const pressor = try daemon.pressor.acquire();
                    defer pressor.release();
                    var reader: std.Io.Reader = .fixed(data);
                    const output = try pressor.decompress(&reader);
                    try packer.put(io, .{ .data = output });
                },
                .end => break,
                else => return error.InvalidPack,
            }
        }
        break :receive_artifacts try temp_dir.realPathFileAlloc(io, ".", gpa);
    };
    defer gpa.free(temp_dir_path);

    if (std.fs.path.dirname(artifact_dir_path)) |parent|
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};

    try std.Io.Dir.cwd().rename(
        temp_dir_path,
        std.Io.Dir.cwd(),
        artifact_dir_path,
        io,
    );
    return .{ .footer = .{} };
}

fn handle_task_spawn(daemon: *Daemon, arena: *std.heap.ArenaAllocator, conn: *Connection) proto.Res(proto.task.spawn.Res) {
    const ara = arena.allocator();
    const gpa = daemon.gpa;
    const io = daemon.io;

    const req = try conn.recv_object(ara, proto.task.spawn.Req);

    const deployment = req.task.deployment.to_string();

    const task: Task = .{ .id = req.task };

    const input_dirs = input_dirs: {
        const input_dirs = try ara.alloc(
            []const u8,
            req.pipeline.inputs().len,
        );
        for (req.pipeline.inputs(), input_dirs) |input, *input_dir| {
            const path = try paths.artifact(
                ara,
                req.task.workspace,
                &deployment,
                input,
            );
            std.Io.Dir.cwd().access(
                daemon.io,
                path,
                .{},
            ) catch |err|
                if (err == error.FileNotFound) {
                    return error.MissingInputArtifact;
                };
            input_dir.* = path;
        }
        break :input_dirs input_dirs;
    };

    const run_dir_path = try task.run_dir_path(ara);

    try std.Io.Dir.cwd().createDirPath(daemon.io, run_dir_path);

    const cwd_dir_path = try std.fs.path.join(ara, &.{ run_dir_path, "cwd" });
    try std.Io.Dir.cwd().createDirPath(daemon.io, cwd_dir_path);

    const script_path = try std.fs.path.join(ara, &.{ run_dir_path, "bin" });

    {
        const script_file = try std.Io.Dir.cwd().createFile(daemon.io, script_path, .{
            .permissions = .executable_file,
        });
        defer script_file.close(io);
        const buffer = try gpa.alloc(u8, Connection.max_packet_size);
        defer gpa.free(buffer);
        while (true) {
            const data = try conn.recv_buf(buffer);
            if (data.len < 5 or !std.mem.eql(u8, data[0..4], "pack"))
                return error.InvalidPack;

            switch (data[4]) {
                proto.data => try script_file.writeStreamingAll(io, data[5..]),
                proto.end => break,
                else => return error.InvalidPack,
            }
        }
    }

    const runner_user = daemon.config.runner.user orelse "weft-runner";
    const is_default_runner = std.mem.eql(u8, runner_user, "weft-runner");

    const home_dir_path = if (is_default_runner)
        try paths.home(ara, req.task.workspace)
    else
        try std.fmt.allocPrint(ara, "/home/{s}", .{runner_user});

    if (is_default_runner)
        try std.Io.Dir.cwd().createDirPath(daemon.io, home_dir_path);

    const output_dir_path = try std.fs.path.join(ara, &.{ run_dir_path, "out" });

    var state_dirs: std.ArrayList([]const u8) = try .initCapacity(ara, req.pipeline.outputs().len + 2);
    try state_dirs.append(ara, paths.state_dir(cwd_dir_path));
    if (is_default_runner)
        try state_dirs.append(ara, paths.state_dir(home_dir_path));

    for (req.pipeline.outputs()) |output| {
        const path = try std.fs.path.join(ara, &.{
            output_dir_path,
            output,
        });
        try std.Io.Dir.cwd().createDirPath(daemon.io, path);
        try state_dirs.append(ara, paths.state_dir(path));
    }
    const unit_name = try task.unit_name(ara);
    var bind_paths: std.ArrayList([]const u8) = .empty;

    for (req.pipeline.keep) |keep| {
        const cache_path = try task.keep_path(ara, keep.@"0");
        const mount_path = try std.fs.path.join(gpa, &.{ cwd_dir_path, keep.@"1" });
        defer gpa.free(mount_path);

        try std.Io.Dir.cwd().createDirPath(io, cache_path);
        try std.Io.Dir.cwd().createDirPath(io, mount_path);
        try state_dirs.append(ara, paths.state_dir(cache_path));
        try bind_paths.append(
            ara,
            try std.fmt.allocPrint(ara, "{s}:{s}", .{ cache_path, mount_path }),
        );
    }

    const archive_dir_path = try task.archive(ara);
    try std.Io.Dir.cwd().createDirPath(daemon.io, archive_dir_path);
    const log_path = try std.fs.path.join(ara, &.{ archive_dir_path, "log.txt" });

    const env = bind_env: {
        var env: std.ArrayList([]const u8) = .empty;
        const input_dir = try paths.artifacts(
            ara,
            req.task.workspace,
            &deployment,
        );
        try env.append(ara, try std.fmt.allocPrint(ara, "IN={s}", .{input_dir}));
        try env.append(ara, try std.fmt.allocPrint(ara, "OUT={s}", .{output_dir_path}));
        try env.append(ara, try std.mem.join(ara, "=", &.{ "HOME", home_dir_path }));
        try env.append(ara, try std.mem.join(ara, "=", &.{ "USER", runner_user }));
        try env.append(ara, try std.mem.join(ara, "=", &.{ "LOGNAME", runner_user }));

        for (req.pipeline.env) |pair|
            try env.append(ara, try std.mem.join(ara, "=", &.{ pair.@"0", pair.@"1" }));
        break :bind_env env;
    };

    switch (req.pipeline.second_instance) {
        .ignore => {},
        .kill => {
            var siblings = try task.siblings(gpa, daemon.io);
            defer siblings.deinit(daemon.io);
            while (try siblings.next(io)) |sibling|
                if (try sibling.is_active(gpa, io))
                    try sibling.kill(gpa, io);
        },
        .fail => {
            var siblings = try task.siblings(gpa, daemon.io);
            defer siblings.deinit(daemon.io);
            while (try siblings.next(io)) |sibling|
                if (try sibling.is_active(gpa, io))
                    return error.AlreadyRunning;
        },
    }

    var child = try systemd.run(
        gpa,
        io,
        unit_name,
        .{
            .cmd = &.{script_path},
            .raw = &.{},
            .unit = .{
                .type = .exec,
                .description = try std.fmt.allocPrint(ara, "Weft runner", .{}),
            },
            .fs = .{
                .inaccessible = &.{},
                .private_tmp = true,
                .protect_system = .strict,
                .read = input_dirs,
                .write = &.{},
                .root_image = null,
                .tmpfs = &.{},
                .bind_paths = bind_paths.items,
            },
            .permissions = .{
                .capability_bounding_set = &.{},
                .protect_control_groups = true,
                .private_devices = true,
                .protect_kernel_modules = true,
                .protect_kernel_tunables = true,
                // .private_network = true,
                // .restrict_address_families = &.{ "AF_UNIX", "AF_INET", "AF_INET6" },
                .no_new_privileges = true,
            },
            .run = .{
                .user = runner_user,
                .group = null,
                .wait = false,
                .collect = true,
                .cwd = cwd_dir_path,
                .dynamic_user = false,
                .state_directories = state_dirs.items,
                .env = env.items,
                .hooks = .{
                    .poststart = try std.fmt.allocPrint(ara, "+/usr/bin/touch {s}/started", .{run_dir_path}),
                    .poststop = try std.fmt.allocPrint(
                        ara,
                        "+/usr/local/bin/weft daemon ipc completed {s} $EXIT_STATUS",
                        .{unit_name},
                    ),
                },
                .stderr = .{ .append = log_path },
                .stdout = .{ .append = log_path },
            },
            .resources = .{
                .memory_max = req.pipeline.memory_max,
                .memory_high = req.pipeline.memory_high,
                .cpu_quota = req.pipeline.cpu_quota,
                .tasks_max = req.pipeline.tasks_max,
                .io_weight = req.pipeline.io_weight,
                .timeout = req.pipeline.timeout,
            },
        },
    );
    const term = try child.wait(daemon.io);
    if (term.exited != 0) {
        daemon.term.err("Systemd task launch failed: {any}", .{term});
        return error.SpawnFailed;
    } else return .{};
}

const max_log_pack_size = 32 << 10;
pub fn handle_task_poll(
    daemon: *Daemon,
    arena: *std.heap.ArenaAllocator,
    conn: *Connection,
    response_buf: []u8,
) proto.Res(proto.task.poll.Res) {
    const cwd = std.Io.Dir.cwd();
    const ara = arena.allocator();
    const gpa = daemon.gpa;
    const io = daemon.io;
    const req = (try conn.recv_object(ara, proto.task.poll.Req)).header;

    for (req.tasks) |item_req| {
        const task: Task = .{ .id = item_req.task };

        const archive_dir_path = task.archive(ara) catch |err| return err;

        var archive_dir = cwd.openDir(io, archive_dir_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try conn.send_object(response_buf, proto.Res(proto.task.poll.Res), .{
                    .item = .{
                        .task = item_req.task,
                        .logs = null,
                        .status = .not_found,
                        .usage = null,
                    },
                });
                continue;
            } else return err;
        };
        defer archive_dir.close(io);

        const status: ?u16 = status: {
            var buf: [2]u8 = undefined;
            const file = archive_dir.openFile(io, "status", .{ .allow_directory = false }) catch |err| {
                if (err == error.FileNotFound)
                    break :status null
                else
                    return err;
            };
            defer file.close(io);
            const s = try file.readStreaming(io, &.{&buf});
            if (s < 2)
                break :status null;
            break :status std.mem.readInt(u16, &buf, .little);
        };

        const logs: ?proto.task.poll.Logs = if (item_req.logs_offset) |offset| read_logs: {
            const logs_file = archive_dir.openFile(
                io,
                "log.txt",
                .{ .allow_directory = false },
            ) catch |err| {
                if (err == error.FileNotFound)
                    break :read_logs null
                else
                    return err;
            };
            defer logs_file.close(io);

            const size = try logs_file.length(io);
            if (size <= offset)
                break :read_logs .{
                    .data = &.{},
                    .compressed = false,
                    .end_offset = size,
                };

            const to_read = @min(size - offset, max_log_pack_size);
            const buff = try ara.alloc(u8, to_read);

            _ = try logs_file.readPositionalAll(io, buff, offset);
            break :read_logs .{
                .data = buff,
                .compressed = false,
                .end_offset = offset + to_read,
            };
        } else null;

        const usage: ?proto.task.poll.TaskUsage = if (status == null) task.usage(gpa, io) else null;

        try conn.send_object(response_buf, proto.Res(proto.task.poll.Res), .{
            .item = .{
                .task = item_req.task,
                .logs = logs,
                .status = if (status) |code|
                    if (code == 0)
                        .success
                    else
                        .{ .failed = code }
                else
                    .running,
                .usage = usage,
            },
        });
    }

    return .{ .footer = .{} };
}
