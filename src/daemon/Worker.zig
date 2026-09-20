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
const Worker = @import("Worker.zig");

const stream_buffer_size = 4 << 10;

pub const worker_heap_mem = 128 << 10;

allocator: std.heap.ArenaAllocator,
running: bool = false,
daemon: *Daemon,

pub fn init(alloc: std.mem.Allocator, daemon: *Daemon) !@This() {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    _ = try arena.allocator().alloc(u8, worker_heap_mem);
    return .{
        .allocator = arena,
        .daemon = daemon,
    };
}

pub fn run(self: *@This(), permits: *std.Io.Semaphore, stream: std.Io.net.Stream) void {
    self._run(stream) catch |err| {
        self.daemon.term.err("worker error: {any}", .{err});
        if (@errorReturnTrace()) |trace|
            std.debug.dumpErrorReturnTrace(trace);
    };

    stream.close(self.daemon.io);
    _ = self.allocator.reset(.{ .retain_with_limit = worker_heap_mem });
    self.running = false;
    permits.post(self.daemon.io);
}

fn _run(self: *@This(), stream: std.Io.net.Stream) !void {
    const alloc = self.allocator.allocator();
    const io = self.daemon.io;

    var reader = stream.reader(io, try alloc.alloc(u8, stream_buffer_size));
    var writer = stream.writer(io, try alloc.alloc(u8, stream_buffer_size));

    var conn: Connection = try .init(io, &try self.daemon.config.get_secret(), &reader.interface, &writer.interface);

    const request = request: {
        var req_buffer: [1 << 10]u8 = undefined;
        break :request conn.recv_object_buf(&req_buffer, proto.Request) catch |err|
            return if (err == error.BufferTooSmall)
                error.InvalidRequest
            else
                err;
    };

    self.daemon.term.info("Request: {any}", .{request});

    const response_buf = try alloc.alloc(u8, Connection.max_packet_size);
    switch (request) {
        .artifact_push => {
            var res: proto.Res(proto.artifact.push.Res) = undefined;
            res = self.handle_artifact_push(&conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                self.daemon.term.err("daemon::worker::artifact_push {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .task_spawn => {
            var res: proto.Res(proto.task.spawn.Res) = undefined;
            res = self.handle_task_spawn(&conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                self.daemon.term.err("daemon::worker::task_spawn {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .artifact_pull => {
            var res: proto.Res(proto.artifact.pull.Res) = undefined;
            res = self.handle_artifact_pull(&conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                self.daemon.term.err("daemon::worker::task_spawn {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .task_poll => {
            var res: proto.Res(proto.task.poll.Res) = undefined;
            res = self.handle_task_poll(&conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                self.daemon.term.err("daemon::worker::task_poll {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .artifact_has => {
            var res: proto.Res(proto.artifact.has.Res) = undefined;
            res = self.handle_artifact_has(&conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                self.daemon.term.err("daemon::worker::artifact_has {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        else => {},
    }
}

fn handle_artifact_has(self: *@This(), conn: *Connection) proto.Res(proto.artifact.has.Res) {
    const alloc = self.allocator.allocator();
    const req = try conn.recv_object(alloc, proto.artifact.has.Req);
    const id = &req.id;
    const deployment = id.deployment.to_string();
    const artifact_dir_path = try paths.artifact(
        alloc,
        id.workspace,
        id.service,
        id.env,
        &deployment,
        id.pipeline,
    );
    const has = has: {
        std.Io.Dir.cwd().access(
            self.daemon.io,
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

fn handle_artifact_pull(self: *@This(), conn: *Connection) proto.Res(proto.artifact.pull.Res) {
    const alloc = self.allocator.allocator();
    const io = self.daemon.io;
    const req = try conn.recv_object(alloc, proto.artifact.pull.Req);
    const id = &req.header.id;
    const deployment = id.deployment.to_string();

    self.daemon.term.info("artifact pull: {s}/{s}/{s}/{s}/{s}", .{
        id.workspace,
        id.service,
        id.env,
        &id.deployment.to_string(),
        id.pipeline,
    });

    const artifact_dir_path = try paths.artifact(
        alloc,
        id.workspace,
        id.service,
        id.env,
        &deployment,
        id.pipeline,
    );

    const artifact_dir = std.Io.Dir.cwd().openDir(
        io,
        artifact_dir_path,
        .{ .iterate = true },
    ) catch |err|
        return if (err == error.FileNotFound)
            error.ArtifactNotFound
        else
            err;

    var file_count: u32 = 0;
    {
        var walker = try artifact_dir.walk(alloc);
        defer walker.deinit();
        while (try walker.next(io)) |entry|
            if (entry.kind == .file) {
                file_count += 1;
            };
    }

    var packer: Packer = try .packer(alloc, artifact_dir);
    defer packer.deinit(io);
    const zoto_buffer = try alloc.alloc(u8, Connection.max_packet_size);
    const packet_buffer = try alloc.alloc(u8, Pressor.chunk_size);

    try conn.send_object(zoto_buffer, proto.artifact.pull.Res, .{ .files = file_count });

    while (try packer.get(io, packet_buffer)) |pack| {
        switch (pack) {
            .file => |path| try conn.send_object(zoto_buffer, proto.artifact.pull.Res, .{ .file = path }),
            .folder => |path| try conn.send_object(zoto_buffer, proto.artifact.pull.Res, .{ .folder = path }),
            .data => |data| if (try self.daemon.pressor.try_acquire()) |pressor| {
                defer pressor.release();
                var reader: std.Io.Reader = .fixed(data);
                if (pressor.compress(&reader)) |compressed| {
                    if (compressed.len < data.len)
                        try conn.send_object(zoto_buffer, proto.artifact.pull.Res, .{ .compressed = compressed })
                    else
                        try conn.send_object(zoto_buffer, proto.artifact.pull.Res, .{ .raw = data });
                } else |_| try conn.send_object(zoto_buffer, proto.artifact.pull.Res, .{ .raw = data });
            } else try conn.send_object(zoto_buffer, proto.artifact.pull.Res, .{ .raw = data }),
        }
    }
    try conn.send_object(zoto_buffer, proto.artifact.pull.Res, .end);
    self.daemon.term.success("handle_artifact_pull:: sent artifact", .{});
    return .{ .footer = .{} };
}

fn handle_artifact_push(self: *@This(), conn: *Connection) proto.Res(proto.artifact.push.Res) {
    const alloc = self.allocator.allocator();
    const io = self.daemon.io;
    var buf: [32]u8 = undefined;
    const req = switch (try conn.recv_object(alloc, proto.artifact.push.Req)) {
        .header => |h| h,
        else => return error.ExpectedHeader,
    };
    const id = &req.id;
    const deployment = id.deployment.to_string();

    self.daemon.term.info("artifact push: {s}/{s}/{s}/{s}/{s}", .{
        id.workspace,
        id.service,
        id.env,
        &id.deployment.to_string(),
        id.pipeline,
    });

    const artifact_dir_path = try paths.artifact(
        alloc,
        id.workspace,
        id.service,
        id.env,
        &deployment,
        id.pipeline,
    );

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
        self.daemon.term.info("artifact already present, skipping upload", .{});
        break :has_artifact true;
    };
    try conn.send_object(&buf, proto.artifact.push.Res, .{ .has_artifact = has_artifact });
    if (has_artifact)
        return .{ .footer = .{} };

    const temp_dir = try self.daemon.install.open_temp(io, "artifact");

    const temp_dir_path = receive_artifacts: {
        var packer: Packer = .unpacker(temp_dir);
        defer packer.deinit(io);

        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        while (true) {
            const raw = try conn.recv_object(arena.allocator(), proto.artifact.push.Req);
            switch (raw) {
                .folder => |path| {
                    try packer.put(io, .{ .folder = path });
                },
                .file => |path| {
                    try packer.put(io, .{ .file = path });
                },
                .data => |data| {
                    try packer.put(io, .{ .data = data });
                },
                .compressed => |data| {
                    const pressor = try self.daemon.pressor.acquire();
                    defer pressor.release();
                    var reader: std.Io.Reader = .fixed(data);
                    const output = try pressor.decompress(&reader);
                    try packer.put(io, .{ .data = output });
                },
                .end => break,
                else => return error.InvalidPack,
            }
            _ = arena.reset(.retain_capacity);
        }
        break :receive_artifacts try temp_dir.realPathFileAlloc(io, ".", alloc);
    };

    if (std.fs.path.dirname(artifact_dir_path)) |parent|
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};

    try std.Io.Dir.cwd().rename(
        temp_dir_path,
        std.Io.Dir.cwd(),
        artifact_dir_path,
        io,
    );
    self.daemon.term.success("artifact stored at {s}", .{artifact_dir_path});
    return .{ .footer = .{} };
}

// tasks
// $IN ->  dir with / symprintln

// setup build env:
// - setup input artifacts as readonly.
// - $IN to /var/lib/weft/artifacts/{w}/{s}/{e}/{d} ($IN/pipeline gives artifact)
//
// - $OUT to /var/lib/weft/run/{w}/{s}/{e}/{d}/{p}/out/{a}
// - cwd to /var/lib/weft/run/{w}/{s}/{e}/{d}/{p}/cwd

fn handle_task_spawn(self: *@This(), conn: *Connection) proto.Res(proto.task.spawn.Res) {
    const alloc = self.allocator.allocator();
    const io = self.daemon.io;
    const term = self.daemon.term;

    const req = try conn.recv_object(alloc, proto.task.spawn.Req);

    const deployment = req.task.deployment.to_string();

    term.info("task spawn: {s}/{s}/{s}/{s}/{s}", .{
        req.task.workspace,
        req.task.env,
        req.task.service,
        &deployment,
        req.task.pipeline,
    });

    const task: Task = .{ .id = req.task };

    var input_dirs = try alloc.alloc(
        []const u8,
        req.pipeline.inputs.len,
    );
    // --- verify inputs
    for (req.pipeline.inputs, 0..) |input, i| {
        const path = try paths.artifact(
            alloc,
            req.task.workspace,
            req.task.service,
            req.task.env,
            &deployment,
            input.name,
        );
        std.Io.Dir.cwd().access(
            self.daemon.io,
            path,
            .{},
        ) catch |err|
            if (err == error.FileNotFound) {
                term.err("missing input artifact: {s}", .{path});
                return error.MissingInputArtifact;
            };
        term.debug("input artifact: {s}", .{path});
        input_dirs[i] = path;
    }

    // --- setup run
    const run_dir_path = try task.run_dir_path(alloc);

    try std.Io.Dir.cwd().createDirPath(self.daemon.io, run_dir_path);
    term.debug("run dir: {s}", .{run_dir_path});

    const cwd_dir_path = try std.fs.path.join(alloc, &.{ run_dir_path, "cwd" });
    try std.Io.Dir.cwd().createDirPath(self.daemon.io, cwd_dir_path);

    // --- setup script
    const script_path = try std.fs.path.join(alloc, &.{ run_dir_path, "bin" });
    const script_file = try std.Io.Dir.cwd().createFile(self.daemon.io, script_path, .{
        .permissions = .executable_file,
    });
    errdefer script_file.close(io);

    while (true) {
        const data = try conn.recv(alloc);
        defer alloc.free(data);
        switch (data[0]) {
            proto.task.spawn.data => {
                try script_file.writeStreamingAll(io, data[1..]);
            },
            proto.task.spawn.end => break,
            else => return error.InvalidPack,
        }
    }
    script_file.close(io);
    term.debug("wrote script: {s}", .{script_path});

    // --- setup env and state

    const home_dir_path = try paths.home(alloc, req.task.workspace);
    try std.Io.Dir.cwd().createDirPath(self.daemon.io, home_dir_path);

    const output_dir_path = try std.fs.path.join(alloc, &.{ run_dir_path, "out" });

    var state_dirs: std.ArrayList([]const u8) = try .initCapacity(alloc, req.pipeline.outputs.len + 1);
    try state_dirs.append(alloc, paths.state_dir(cwd_dir_path));
    try state_dirs.append(alloc, paths.state_dir(home_dir_path));
    // --- setup pipeline outputs

    for (req.pipeline.outputs) |output| {
        const path = try std.fs.path.join(alloc, &.{
            output_dir_path,
            output.name,
        });
        try std.Io.Dir.cwd().createDirPath(self.daemon.io, path);
        try state_dirs.append(alloc, paths.state_dir(path));
    }
    const unit_name = try task.unit_name(alloc);
    const input_dir = try paths.artifacts(
        alloc,
        req.task.workspace,
        req.task.service,
        req.task.env,
        &deployment,
    );
    // setup pipeline keep
    var bind_paths: std.ArrayList([]const u8) = .empty;
    for (req.pipeline.keep) |keep| {
        const cache_path = try task.keep_path(alloc, keep.@"0");
        const mount_path = try std.fs.path.join(alloc, &.{ cwd_dir_path, keep.@"1" });
        defer alloc.free(mount_path);

        try std.Io.Dir.cwd().createDirPath(io, cache_path);
        try std.Io.Dir.cwd().createDirPath(io, mount_path);
        try state_dirs.append(alloc, paths.state_dir(cache_path));
        try bind_paths.append(
            alloc,
            try std.fmt.allocPrint(alloc, "{s}:{s}", .{ cache_path, mount_path }),
        );
    }

    const archive_dir_path = try task.archive(alloc);
    defer alloc.free(archive_dir_path);
    try std.Io.Dir.cwd().createDirPath(self.daemon.io, archive_dir_path);
    const log_path = try std.fs.path.join(alloc, &.{ archive_dir_path, "log.txt" });

    // --- bind environment variables
    var env: std.ArrayList([]const u8) = .empty;

    try env.append(alloc, try std.fmt.allocPrint(alloc, "IN={s}", .{input_dir}));
    try env.append(alloc, try std.fmt.allocPrint(alloc, "OUT={s}", .{output_dir_path}));
    try env.append(alloc, try std.mem.join(alloc, "=", &.{ "HOME", home_dir_path }));

    for (req.pipeline.env) |pair|
        try env.append(alloc, try std.mem.join(alloc, "=", &.{ pair.@"0", pair.@"1" }));

    // --- handle other instances
    switch (req.pipeline.second_instance) {
        .ignore => {},
        .kill => {
            var siblings = try task.siblings(alloc, self.daemon.io);
            while (try siblings.next(io)) |sibling| {
                try sibling.kill(alloc, io);
            }
        },
    }

    var child = try systemd.run(
        alloc,
        io,
        unit_name,
        .{
            .cmd = &.{script_path},
            .raw = &.{},
            .unit = .{
                .type = .exec,
                .description = try std.fmt.allocPrint(alloc, "Weft runner", .{}),
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
                .user = "weft-runner",
                .group = null,
                .wait = false,
                .collect = true,
                .cwd = cwd_dir_path,
                .dynamic_user = false,
                .state_directories = state_dirs.items,
                .env = env.items,
                .hooks = .{
                    .poststart = try std.fmt.allocPrint(alloc, "+/usr/bin/touch {s}/started", .{run_dir_path}),
                    .poststop = try std.fmt.allocPrint(
                        alloc,
                        "+/usr/local/bin/weft _daemon completed {s} $EXIT_STATUS",
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
    _ = try child.wait(self.daemon.io);

    term.success("task {s} started", .{req.task.pipeline});

    return .{};
}

const max_log_pack_size = 32 << 10;
const task_not_found: proto.task.poll.Res = .{ .footer = .{ .logs = null, .status = .not_found } };
pub fn handle_task_poll(self: *@This(), conn: *Connection) proto.Res(proto.task.poll.Res) {
    const cwd = std.Io.Dir.cwd();
    const alloc = self.allocator.allocator();
    const io = self.daemon.io;
    const req = (try conn.recv_object(alloc, proto.task.poll.Req)).header;

    const task: Task = .{ .id = req.task };

    const archive_dir_path = try task.archive(alloc);
    defer alloc.free(archive_dir_path);

    const archive_dir = cwd.openDir(io, archive_dir_path, .{}) catch |err|
        return if (err == error.FileNotFound)
            task_not_found
        else
            err;
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

    const logs: ?proto.task.poll.Logs = if (req.logs_offset) |offset| read_logs: {
        const logs_file = archive_dir.openFile(
            io,
            "log.txt",
            .{ .allow_directory = false },
        ) catch |err|
            return if (err == error.FileNotFound)
                task_not_found
            else
                err;
        defer logs_file.close(io);

        const size = try logs_file.length(io);
        if (size <= offset)
            break :read_logs .{
                .data = &.{},
                .compressed = false,
                .end_offset = size,
            };

        const to_read = @min(size - offset, max_log_pack_size);
        const buff = try alloc.alloc(u8, to_read);

        _ = try logs_file.readPositionalAll(io, buff, offset);
        break :read_logs .{
            .data = buff,
            .compressed = false,
            .end_offset = offset + to_read,
        };
    } else null;

    return .{ .footer = .{
        .logs = logs,
        .status = if (status) |code|
            if (code == 0)
                .success
            else
                .{ .failed = code }
        else
            .running,
    } };
}
