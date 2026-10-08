const std = @import("std");
const log = std.log.scoped;

const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const systemd = @import("../util/systemd.zig");
const zoto = @import("../util/zoto.zig");
const Connection = @import("../wire/Connection.zig");
const Packer = @import("../wire/Packer.zig");
const Pressor = @import("../wire/Pressor.zig");
const clinternal = @import("clinternal.zig");
const Daemon = @import("Daemon.zig");
const DaemonInstall = @import("DaemonInstall.zig");
const gc = @import("gc.zig");
const Server = @import("Server.zig");
const Task = @import("Task.zig");

pub fn handle(daemon: *Daemon, permits: *std.Io.Semaphore, stream: std.Io.net.Stream) !void {
    const l = log(.client_server);
    defer permits.post(daemon.io);
    errdefer stream.close(daemon.io);

    _run(daemon, stream) catch |err| {
        if (err == error.ReAssigned)
            return;
        l.err("worker error: {any}", .{err});
        if (@errorReturnTrace()) |trace|
            std.debug.dumpErrorReturnTrace(trace);
    };

    stream.close(daemon.io);
}

fn _run(daemon: *Daemon, stream: std.Io.net.Stream) !void {
    const l = log(.client_server);
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const reader_buf = try gpa.alloc(u8, 4 << 10);
    defer gpa.free(reader_buf);
    const writer_buf = try gpa.alloc(u8, 4 << 10);
    defer gpa.free(writer_buf);

    var reader = stream.reader(daemon.io, reader_buf);
    var writer = stream.writer(daemon.io, writer_buf);

    var conn = try daemon.connect(
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

    const response_buf = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(response_buf);
    switch (request) {
        .artifact_push => {
            const res = handle_artifact_push(daemon, &arena, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::artifact_push {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .task_spawn => {
            const res = handle_task_spawn(daemon, &arena, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::task_spawn {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .artifact_pull => {
            const res = handle_artifact_pull(daemon, &arena, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::artifact_pull {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .task_poll => {
            const res = handle_task_poll(daemon, &arena, &conn, response_buf) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::task_poll {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .artifact_has => {
            const res = handle_artifact_has(daemon, &arena, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::artifact_has {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .system_stats => {
            const req = try conn.recv_object_buf(response_buf, proto.system.stats.Req);
            try daemon.stats_server.add_listener(stream, req.from);
            return error.ReAssigned;
        },
        .task_kill => {
            const res = handle_task_kill(daemon, &arena, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::task_kill {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
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
        var temp_dir = try DaemonInstall.open_temp(io, "artifact");
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
    const l = log(.handle_task_spawn);
    const alloc = arena.allocator();
    const gpa = daemon.gpa;
    const io = daemon.io;

    const req = try conn.recv_object(alloc, proto.task.spawn.Req);
    const spec = req.spec;

    const task: Task = .{ .id = spec.task_id };

    const deployment = task.id.deployment.to_string();

    const input_dirs = input_dirs: {
        const input_dirs = try alloc.alloc(
            []const u8,
            spec.inputs.len,
        );
        for (spec.inputs, input_dirs) |input, *input_dir| {
            const path = try paths.artifact(
                alloc,
                spec.task_id.workspace,
                &deployment,
                input,
            );
            std.Io.Dir.cwd().access(
                daemon.io,
                path,
                .{},
            ) catch |err|
                if (err == error.FileNotFound)
                    return error.MissingInputArtifact;

            input_dir.* = path;
        }
        break :input_dirs input_dirs;
    };

    const archive_dir_path = try task.archive(alloc);
    try std.Io.Dir.cwd().createDirPath(daemon.io, archive_dir_path);
    const log_path = try std.fs.path.join(alloc, &.{ archive_dir_path, "log.txt" });
    var log_file = try std.Io.Dir.cwd().createFile(daemon.io, log_path, .{ .truncate = false });
    defer log_file.close(io);

    // vehement leak, but it's just a few bytes
    try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::pkg] Installing packages\n", .{}));
    for (spec.pkgs) |basename| {
        try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::pkg] installing {s}...\n", .{basename}));
        daemon.store.fetch(io, basename) catch |err| {
            try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::pkg] failed to fetch {s}: {s}\n", .{ basename, @errorName(err) }));
            return err;
        };
        try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::pkg] installed {s}\n", .{basename}));
    }
    try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::pkg] done\n", .{}));
    try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::spawner] setting up environment\n", .{}));

    const run_dir_path = try task.run_dir_path(alloc);

    try std.Io.Dir.cwd().createDirPath(daemon.io, run_dir_path);

    const cwd_dir_path = try std.fs.path.join(alloc, &.{ run_dir_path, "cwd" });
    try std.Io.Dir.cwd().createDirPath(daemon.io, cwd_dir_path);

    const script_path = try std.fs.path.join(alloc, &.{ run_dir_path, "bin" });

    const nothing = if (spec.script) |script| script: {
        const script_file = try std.Io.Dir.cwd().createFile(daemon.io, script_path, .{
            .permissions = .executable_file,
        });
        defer script_file.close(io);
        try script_file.writeStreamingAll(io, script);
        break :script false;
    } else true;

    const runner_user = daemon.config.runner_user orelse "weft-runner";
    try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::spawner] running task as {s}\n", .{runner_user}));
    const is_default_runner = std.mem.eql(u8, runner_user, "weft-runner");

    const home_dir_path = if (is_default_runner)
        try paths.home(alloc, spec.task_id.workspace)
    else
        try std.fmt.allocPrint(alloc, "/home/{s}", .{runner_user});

    if (is_default_runner)
        try std.Io.Dir.cwd().createDirPath(daemon.io, home_dir_path);

    const output_dir_path = try std.fs.path.join(alloc, &.{ run_dir_path, "out" });

    var state_dirs: std.ArrayList([]const u8) = try .initCapacity(alloc, spec.outputs.len + 2);
    try state_dirs.append(alloc, paths.state_dir(cwd_dir_path));
    if (is_default_runner)
        try state_dirs.append(alloc, paths.state_dir(home_dir_path));

    for (spec.outputs) |output| {
        const path = try std.fs.path.join(alloc, &.{
            output_dir_path,
            output,
        });
        try std.Io.Dir.cwd().createDirPath(daemon.io, path);
        try state_dirs.append(alloc, paths.state_dir(path));
    }
    const unit_name = try task.unit_name(alloc);
    var bind_paths: std.ArrayList([]const u8) = .empty;
    var bind_paths_read: std.ArrayList([]const u8) = .empty;

    if (spec.pkgs.len > 0) {
        try bind_paths_read.append(alloc, "/var/lib/weft/store:/nix/store");
        try bind_paths_read.append(alloc, "/var/lib/weft/store");
    }

    for (spec.keep) |keep| {
        const cache_path = try task.keep_path(alloc, keep.@"0");
        const mount_path = try std.fs.path.join(gpa, &.{ cwd_dir_path, keep.@"1" });
        defer gpa.free(mount_path);

        try std.Io.Dir.cwd().createDirPath(io, cache_path);
        try std.Io.Dir.cwd().createDirPath(io, mount_path);
        try state_dirs.append(alloc, paths.state_dir(cache_path));
        try bind_paths.append(
            alloc,
            try std.fmt.allocPrint(alloc, "{s}:{s}", .{ cache_path, mount_path }),
        );
    }

    const env = bind_env: {
        var env: std.ArrayList([]const u8) = .empty;
        const input_dir_path = try paths.artifacts(
            alloc,
            spec.task_id.workspace,
            &deployment,
        );
        const env_vars = [_][2][]const u8{
            .{ "IN", input_dir_path },
            .{ "OUT", output_dir_path },

            .{ "HOME", home_dir_path },
            .{ "USER", runner_user },
            .{ "LOGNAME", runner_user },

            .{ "WEFT_MODE", spec.mode },
            .{ "WEFT_PIPELINE", spec.task_id.pipeline },
            .{ "WEFT_WORKSPACE", spec.task_id.workspace },
            .{ "WEFT_DEPLOYMENT", &deployment },
            .{ "WEFT_UNIT", unit_name },
        };
        for (&env_vars) |v|
            try env.append(alloc, try std.mem.join(alloc, "=", &v));

        if (spec.pkgs.len > 0) {
            var pkg_bin_paths: std.ArrayList([]const u8) = .empty;
            for (spec.pkgs) |basename| {
                const bin_dir = try std.fmt.allocPrint(alloc, "/nix/store/{s}/bin", .{basename});
                try pkg_bin_paths.append(alloc, bin_dir);
            }
            const joined_bins = try std.mem.join(alloc, ":", pkg_bin_paths.items);
            try env.append(alloc, try std.fmt.allocPrint(alloc, "PATH={s}:/usr/local/bin:/usr/bin:/bin", .{joined_bins}));
        }

        for (spec.vars) |pair|
            try env.append(alloc, try std.mem.join(alloc, "=", &.{ pair.@"0", pair.@"1" }));
        break :bind_env env;
    };

    const skip = handle_siblings: {
        try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::spawner] handling sibling instances(second_instance = {any})\n", .{spec.sibling}));
        const do_sibling = spec.sibling;
        if (do_sibling.poll <= 0)
            return error.InvalidSiblingConfig;

        var waited: u32 = 0;
        while (waited < do_sibling.wait) : (waited += do_sibling.poll) {
            var sibling_iter = try task.siblings(
                gpa,
                io,
                false,
            );
            defer sibling_iter.deinit(io);
            const sibling: Task = while (try sibling_iter.next(io)) |sibl| {
                if (try sibl.is_active(gpa, io))
                    break sibl;
            } else break;

            const unit = try sibling.unit_name(gpa);
            defer gpa.free(unit);
            try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::spawner] Waiting {d}s for sibling instance {s}\n", .{ do_sibling.wait - waited, unit }));
            try std.Io.sleep(io, .fromSeconds(do_sibling.poll), .awake);
        }

        switch (spec.sibling.then) {
            .ignore => {},
            .kill => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);
                while (try siblings.next(io)) |sibling|
                    if (try sibling.is_active(gpa, io)) {
                        try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::spawner] killing sibling task from {s}\n", .{&sibling.id.deployment.to_string()}));
                        try sibling.kill(gpa, io);
                    };
            },
            .fail => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);
                while (try siblings.next(io)) |sibling|
                    if (try sibling.is_active(gpa, io)) {
                        try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::spawner] found sibling {s}; failing\n", .{&sibling.id.deployment.to_string()}));
                        return error.AlreadyRunning;
                    };
            },
            .skip => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);

                break :handle_siblings while (try siblings.next(io)) |sibling| {
                    if (try sibling.is_active(gpa, io))
                        break true;
                } else false;
            },
        }

        break :handle_siblings false;
    };

    if (skip) {
        try log_file.writeStreamingAll(io, "[weft::spawner] Task is skipped \n");
        try clinternal.task_completed(gpa, io, task, -1);
        return .skipped;
    } else if (nothing) {
        try log_file.writeStreamingAll(io, "[weft::spawner] Task runs nothing \n");
        try clinternal.task_completed(gpa, io, task, -2);
        return .spawned;
    } else {
        try log_file.writeStreamingAll(io, "[weft::spawner] Spawning systemd-run for task ");
        try log_file.writeStreamingAll(io, unit_name);
        try log_file.writeStreamingAll(io, "\n");

        var child = try systemd.run(
            gpa,
            io,
            unit_name,
            .{
                .cmd = if (!skip) &.{script_path} else &.{ "/usr/bin/echo", "[weft.daemon.runner] Pipeline skipped" },
                .raw = &.{},
                .unit = .{
                    .type = .exec,
                    .description = try std.fmt.allocPrint(alloc, "Weft runner", .{}),
                },
                .fs = .{
                    .inaccessible = &.{ "/etc/weft", paths.weft_runtime_dir },
                    .private_tmp = true,
                    .protect_system = .strict,
                    .read = input_dirs,
                    .write = &.{},
                    .root_image = null,
                    .tmpfs = &.{},
                    .bind_paths = bind_paths.items,
                    .bind_paths_read = bind_paths_read.items,
                },
                .permissions = .{
                    .capability_bounding_set = &.{},
                    .protect_control_groups = true,
                    .private_devices = true,
                    .protect_kernel_modules = true,
                    .protect_kernel_tunables = true,
                    .private_network = spec.tune.disable_network,
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
                        .poststart = try std.fmt.allocPrint(alloc, "+/bin/touch {s}/started", .{run_dir_path}),
                        .poststop = try std.fmt.allocPrint(
                            alloc,
                            "+/usr/local/bin/weft daemon ipc completed {s} $EXIT_STATUS",
                            .{unit_name},
                        ),
                    },
                    .stderr = .{ .append = log_path },
                    .stdout = .{ .append = log_path },
                },
                .resources = .{
                    .memory_max = spec.tune.memory_max,
                    .memory_high = spec.tune.memory_high,
                    .cpu_quota = spec.tune.cpu_quota,
                    .tasks_max = spec.tune.tasks_max,
                    .io_weight = spec.tune.io_weight,
                    .timeout = spec.tune.timeout,
                },
            },
        );
        const term = try child.wait(daemon.io);
        try log_file.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "[weft::spawner] systemd-run exited with: {any} \n", .{term}));
        if (term.exited != 0) {
            l.err("Systemd task launch failed: {any}", .{term});
            return error.SpawnFailed;
        } else return .spawned;
    }
}

const max_log_pack_size = 32 << 10;
pub fn handle_task_poll(
    daemon: *Daemon,
    arena: *std.heap.ArenaAllocator,
    conn: *Connection,
    response_buf: []u8,
) proto.Res(proto.task.poll.Res) {
    const l = log(.handle_task_poll);
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

        const status: ?i32 = status: {
            var buf: [32]u8 = undefined;
            const file = archive_dir.openFile(
                io,
                "status",
                .{ .allow_directory = false },
            ) catch |err|
                if (err == error.FileNotFound)
                    break :status null
                else
                    return err;

            defer file.close(io);
            const s = file.readPositionalAll(io, &buf, 0) catch |err| {
                l.warn("Could not read status file: {any}", .{err});
                return err;
            };

            if (s == 0)
                break :status null;

            const trimmed = std.mem.trim(u8, buf[0..s], " \r\n\t");
            if (trimmed.len == 0)
                break :status null
            else
                break :status std.fmt.parseInt(i32, trimmed, 10) catch |err| {
                    l.warn("Could not parse status '{s}': {any}", .{ trimmed, err });
                    return err;
                };
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

        if (status) |s|
            if (s < -3 or s > std.math.maxInt(u16)) {
                l.err("Invalid exit status: {any}", .{s});
                return error.InvalidStatus;
            };
        try conn.send_object(response_buf, proto.Res(proto.task.poll.Res), .{
            .item = .{
                .task = item_req.task,
                .logs = logs,
                .status = if (status) |s|
                    if (s == 0 or s == -2)
                        .success
                    else if (s == -1)
                        .skipped
                    else if (s == -3)
                        .stopped
                    else
                        .{ .failed = @intCast(s) }
                else
                    .running,
                .usage = usage,
            },
        });
    }

    return .{ .footer = .{} };
}

fn handle_task_kill(daemon: *Daemon, arena: *std.heap.ArenaAllocator, conn: *Connection) proto.Res(proto.task.kill.Res) {
    const ara = arena.allocator();
    const io = daemon.io;

    const req = try conn.recv_object(ara, proto.task.kill.Req);
    const task: Task = .{ .id = .{
        .deployment = req.deployment,
        .pipeline = req.pipeline,
        .workspace = req.workspace,
    } };
    try task.kill(ara, io);
    return .{ .footer = .{} };
}
