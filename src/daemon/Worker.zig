const std = @import("std");

const Connection = @import("../Connection.zig");
const DaemonInstall = @import("../DaemonInstall.zig");
const Packer = @import("../Packer.zig");
const Pressor = @import("../Pressor.zig");
const proto = @import("../proto.zig");
const Server = @import("../Server.zig");
const systemd = @import("../systemd.zig");
const Term = @import("../Term.zig");
const zoto = @import("../zoto.zig");
const Daemon = @import("Daemon.zig");
const paths = @import("paths.zig");
const Worker = @import("Worker.zig");

const stream_buffer_size = 4 << 10;

pub const worker_heap_mem = 128 << 10;

allocator: std.heap.FixedBufferAllocator,
running: bool = false,
daemon: *Daemon,

pub fn init(memory: []u8, daemon: *Daemon) !@This() {
    return .{
        .allocator = .init(memory),
        .daemon = daemon,
    };
}

pub fn run(self: *@This(), permits: *std.Io.Semaphore, stream: std.Io.net.Stream) void {
    self._run(stream) catch |err|
        self.daemon.term.err("worker error: {any}", .{err}) catch {};

    stream.close(self.daemon.io);
    self.allocator.reset();
    _ = std.os.linux.madvise(self.allocator.buffer.ptr, self.allocator.buffer.len, std.os.linux.MADV.DONTNEED);
    self.running = false;
    permits.post(self.daemon.io);
}

fn _run(self: *@This(), stream: std.Io.net.Stream) !void {
    const alloc = self.allocator.allocator();
    const io = self.daemon.io;

    var reader = stream.reader(io, try alloc.alloc(u8, stream_buffer_size));
    var writer = stream.writer(io, try alloc.alloc(u8, stream_buffer_size));

    var conn: Connection = try .init(io, &self.daemon.config.secret, &reader.interface, &writer.interface);

    const request = request: {
        var req_buffer: [16]u8 = undefined;
        break :request conn.recv_object_buf(&req_buffer, proto.Request) catch |err|
            return if (err == error.BufferTooSmall)
                error.InvalidRequest
            else
                err;
    };

    try self.daemon.term.info("Request: {any}", .{request});

    var response_buf: [16]u8 = undefined;
    switch (request) {
        .artifact_push => self.handle_artifact_push(&conn) catch |err|
            try conn.send_object(&response_buf, @as(anyerror!proto.artifact.push.Res, err)),
        .task_spawn => self.handle_task_spawn(&conn) catch |err|
            try conn.send_object(&response_buf, @as(anyerror!proto.task.spawn.Res, err)),
        else => return error.NotImplemented,
    }
}

fn handle_artifact_push(self: *@This(), conn: *Connection) !void {
    const alloc = self.allocator.allocator();
    const io = self.daemon.io;
    var buf: [32]u8 = undefined;
    const req = try conn.recv_object(alloc, proto.artifact.push.Req);
    const id = &req.id;

    const deployment = id.deployment.to_string();

    try self.daemon.term.info("artifact push: {s}/{s}/{s}/{s}/{s}", .{
        id.workspace,
        id.workspace,
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

    has_artifact: {
        std.Io.Dir.cwd().access(
            io,
            artifact_dir_path,
            .{},
        ) catch |err|
            if (err == error.FileNotFound)
                break :has_artifact
            else
                return err;
        try self.daemon.term.info("artifact already present, skipping upload", .{});
        try conn.send_object(&buf, true);
        return;
    }
    try conn.send_object(&buf, false);

    const temp_dir = try self.daemon.install.open_temp(io, "artifact");
    defer temp_dir.close(io);

    receive_artifacts: {
        var packer: Packer = try .unpacker(temp_dir);
        defer packer.deinit(io);

        while (true) {
            const raw = try conn.recv(alloc);
            defer alloc.free(raw);
            const data = raw[1..];
            switch (raw[0]) {
                proto.artifact.push.folder => {
                    try packer.put(io, .{ .folder = data });
                },
                proto.artifact.push.file => {
                    try packer.put(io, .{ .file = data });
                },
                proto.artifact.push.raw => {
                    try packer.put(io, .{ .data = data });
                },
                proto.artifact.push.compressed => {
                    const pressor = try self.daemon.pressor.acquire();
                    defer pressor.release();
                    var reader: std.Io.Reader = .fixed(data);
                    const output = try pressor.decompress(&reader);
                    try packer.put(io, .{ .data = output });
                },
                proto.artifact.push.end => break,

                else => return error.InvalidPack,
            }
        }
        break :receive_artifacts;
    }

    if (std.fs.path.dirname(artifact_dir_path)) |parent|
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};

    try std.Io.Dir.cwd().rename(
        try temp_dir.realPathFileAlloc(
            io,
            ".",
            alloc,
        ),
        std.Io.Dir.cwd(),
        artifact_dir_path,
        io,
    );
    var buff: [32]u8 = undefined;
    try conn.send_object(&buff, @as(anyerror!proto.artifact.push.Res, proto.artifact.push.Res{}));
    self.daemon.term.success("artifact stored at {s}", .{artifact_dir_path}) catch {};
}

// tasks
// $IN ->  dir with / symprintln

// setup build env:
// - setup input artifacts as readonly.
// - $IN to /var/lib/weft/artifacts/{w}/{s}/{e}/{d} ($IN/pipeline gives artifact)
//
// - $OUT to /var/lib/weft/run/{w}/{s}/{e}/{d}/{p}/out/{a}
// - cwd to /var/lib/weft/run/{w}/{s}/{e}/{d}/{p}/cwd

fn handle_task_spawn(self: *@This(), conn: *Connection) !void {
    const alloc = self.allocator.allocator();
    const io = self.daemon.io;
    const term = self.daemon.term;

    const req = try conn.recv_object(alloc, proto.task.spawn.Req);

    const deployment = req.task.deployment.to_string();

    try term.info("task spawn: {s}/{s}/{s}/{s}/{s}", .{
        req.task.workspace,
        req.task.env,
        req.task.service,
        &deployment,
        req.task.pipeline,
    });

    const unit_name = try paths.unit_name(
        alloc,
        req.task.workspace,
        req.task.env,
        req.task.service,
        &deployment,
        req.task.pipeline,
    );
    try term.debug("unit name: {s}", .{unit_name});

    const input_dir = try paths.artifacts(
        alloc,
        req.task.workspace,
        req.task.service,
        req.task.env,
        &deployment,
    );

    var input_dirs = try alloc.alloc(
        []const u8,
        req.pipeline.inputs.len,
    );
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
                try term.err("missing input artifact: {s}", .{path});
                return error.MissingInputArtifact;
            };
        try term.debug("input artifact: {s}", .{path});
        input_dirs[i] = path;
    }

    const run_dir_path = try paths.run(
        alloc,
        req.task.workspace,
        req.task.service,
        req.task.env,
        &deployment,
        req.task.pipeline,
    );

    try std.Io.Dir.cwd().createDirPath(self.daemon.io, run_dir_path);
    try term.debug("run dir: {s}", .{run_dir_path});

    const cwd_dir_path = try std.fs.path.join(alloc, &.{ run_dir_path, "cwd" });
    try std.Io.Dir.cwd().createDirPath(self.daemon.io, cwd_dir_path);

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
    try term.debug("wrote script: {s}", .{script_path});

    const output_dir_path = try std.fs.path.join(alloc, &.{ run_dir_path, "out" });

    var write_dirs: std.ArrayList([]const u8) = try .initCapacity(alloc, req.pipeline.outputs.len + 1);
    for (req.pipeline.outputs) |output| {
        const path = try std.fs.path.join(alloc, &.{
            output_dir_path,
            output.name,
        });
        try std.Io.Dir.cwd().createDirPath(self.daemon.io, path);
        try write_dirs.append(alloc, path);
    }
    try write_dirs.append(alloc, cwd_dir_path);

    try term.info("starting systemd unit {s}", .{unit_name});

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
                .write = write_dirs.items,
                .root_image = null,
                .tmpfs = &.{},
            },
            .permissions = .{
                .capability_bounding_set = &.{},
                .protect_control_groups = true,
                .private_devices = true,
                .protect_kernel_modules = true,
                .protect_kernel_tunables = true,
                .private_network = true,
                .no_new_privileges = true,
                .restrict_address_families = &.{ "AF_UNIX", "AF_INET", "AF_INET6" },
            },
            .run = .{
                .user = "weft-runner",
                .group = null,
                .wait = false,
                .collect = true,
                .cwd = cwd_dir_path,
                .dynamic_user = false,
                .env = &.{
                    try std.fmt.allocPrint(alloc, "IN={s}", .{input_dir}),
                    try std.fmt.allocPrint(alloc, "OUT={s}", .{output_dir_path}),
                },
            },
            .resources = .{},
        },
    );
    _ = try child.wait(self.daemon.io);

    try term.success("task {s} started", .{req.task.pipeline});
    var buf: [32]u8 = undefined;
    try conn.send_object(&buf, @as(anyerror!proto.task.spawn.Res, proto.task.spawn.Res{}));

    return;
}
