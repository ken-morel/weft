const Connection = @import("../Connection.zig");
const Server = @import("../Server.zig");
const std = @import("std");
const DaemonInstall = @import("../DaemonInstall.zig");
const Term = @import("../Term.zig");
const Worker = @import("Worker.zig");
const packer = @import("../packer.zig");
const Daemon = @import("Daemon.zig");
const systemd = @import("../systemd.zig");

const max_worker_mem = 256 << 10;

memory: []u8,
allocator: std.heap.FixedBufferAllocator,
running: bool = false,
daemon: *Daemon,

pub fn init(alloc: std.mem.Allocator, daemon: *Daemon) !@This() {
    const memory = try alloc.alloc(u8, max_worker_mem);
    return .{
        .memory = memory,
        .allocator = .init(memory),
        .daemon = daemon,
    };
}

pub fn handle(self: *@This(), req: *Server.Request) !void {
    const alloc = self.allocator.allocator();
    defer {
        self.allocator.reset();
        _ = std.os.linux.madvise(self.memory.ptr, self.memory.len, std.os.linux.MADV.DONTNEED);
    }
    defer req.destroy(alloc, self.daemon.io);

    const msg = req.conn.recv_ref(
        null,
    ) catch |err|
        return if (err == error.EndOfStream)
            return error.EmptyRequest
        else
            err;

    try self.daemon.term.debug("recv: {any}", .{msg});

    switch (msg) {
        .request => |r| switch (r) {
            .artifact_push => try self.handle_artifact_push(req),
            .task_spawn => try self.handle_task_spawn(req),
            else => try self.daemon.term.warn("unhandled request type: {any}", .{r}),
        },
        else => return error.InvalidRequest,
    }
}
fn handle_artifact_push(self: *@This(), req: *Server.Request) !void {
    const conn = &req.conn;

    const alloc = self.allocator.allocator();

    const artifact_id = switch (try conn.recv_dupe(alloc)) {
        .artifact_id => |art_id| art_id,
        else => return error.SyntaxEror,
    };

    try self.daemon.term.info("artifact push: {s}/{s}/{s}/{s}/{s}", .{
        artifact_id.service.workspace,
        artifact_id.service.workspace,
        artifact_id.env,
        &artifact_id.deployment.to_string(),
        artifact_id.pipeline,
    });

    const artifact_dir_path = try std.fs.path.join(alloc, &.{
        "/var/lib/weft/artifacts",
        artifact_id.service.workspace,
        artifact_id.service.workspace,
        artifact_id.env,
        &artifact_id.deployment.to_string(),
        artifact_id.pipeline,
    });

    const has_artifact = has_artifact: {
        std.Io.Dir.cwd().access(
            self.daemon.io,
            artifact_dir_path,
            .{},
        ) catch |err|
            if (err == error.FileNotFound)
                break :has_artifact false
            else
                return err;
        break :has_artifact true;
    };
    try conn.send(.{ .bool = has_artifact });

    if (has_artifact) {
        try self.daemon.term.info("artifact already present, skipping upload", .{});
        return;
    }

    const temp_dir = try self.daemon.install.open_temp(self.daemon.io, "artifact");
    defer temp_dir.close(self.daemon.io);

    {
        var unpacker: *packer.Unpacker = try .init(alloc, temp_dir);
        defer unpacker.destroy(alloc, self.daemon.io);

        while (true) {
            const pack = try conn.recv_ref(null);
            switch (pack) {
                .folder => |folder| try unpacker.folder(self.daemon.io, folder),
                .file => |file| try unpacker.file(self.daemon.io, file),
                .data => |data| try unpacker.chunk(self.daemon.io, data),
                .end => break,
                else => return error.SyntaxError,
            }
        }
    }

    if (std.fs.path.dirname(artifact_dir_path)) |parent|
        std.Io.Dir.cwd().createDirPath(self.daemon.io, parent) catch {};

    try std.Io.Dir.cwd().rename(
        try temp_dir.realPathFileAlloc(
            self.daemon.io,
            ".",
            alloc,
        ),
        std.Io.Dir.cwd(),
        artifact_dir_path,
        self.daemon.io,
    );
    try conn.send(.ok);
    try self.daemon.term.success("artifact stored at {s}", .{artifact_dir_path});
}

// tasks
// $IN ->  dir with / symprintln

// setup build env:
// - setup input artifacts as readonly.
// - $IN to /var/lib/weft/artifacts/{w}/{s}/{e}/{d} ($IN/pipeline gives artifact)
//
// - $OUT to /var/lib/weft/run/{w}/{s}/{e}/{d}/{p}/out/{a}
// - cwd to /var/lib/weft/run/{w}/{s}/{e}/{d}/{p}/cwd

pub fn handle_task_spawn(self: *@This(), req: *Server.Request) !void {
    const alloc = self.allocator.allocator();

    const task = switch (try req.conn.recv_dupe(alloc)) {
        .task_spec => |spec| spec,
        else => return error.SyntaxEror,
    };

    try self.daemon.term.info("task spawn: {s}/{s}/{s}/{s}/{s}", .{
        task.workspace,
        task.env,
        task.service,
        &task.deployment.to_string(),
        task.pipline.name,
    });

    const deployment = task.deployment.to_string();
    const unit_name = try std.mem.join(
        alloc,
        "--",
        &.{
            "weft-runner",
            task.workspace,
            task.env,
            task.service,
            &deployment,
            task.pipline.name,
        },
    );
    try self.daemon.term.debug("unit name: {s}", .{unit_name});
    const input_dir = try std.fs.path.join(
        alloc,
        &.{
            "/var/lib/weft/artifacts/",
            task.workspace,
            task.service,
            task.env,
            &deployment,
        },
    );

    var input_dirs = try alloc.alloc(
        []const u8,
        task.pipline.inputs.len,
    );
    for (task.pipline.inputs, 0..) |input, i| {
        const path = try std.fs.path.join(
            alloc,
            &.{ input_dir, input.name },
        );
        std.Io.Dir.cwd().access(
            self.daemon.io,
            path,
            .{},
        ) catch |err|
            if (err == error.FileNotFound) {
                try self.daemon.term.err("missing input artifact: {s}", .{path});
                return error.MissingInput;
            };
        try self.daemon.term.debug("input artifact: {s}", .{path});
        input_dirs[i] = path;
    }

    const run_dir_path = try std.fs.path.join(
        alloc,
        &.{
            "/var/lib/weft/run",
            task.workspace,
            task.service,
            task.env,
            &deployment,
            task.pipline.name,
        },
    );

    try std.Io.Dir.cwd().createDirPath(self.daemon.io, run_dir_path);
    try self.daemon.term.debug("run dir: {s}", .{run_dir_path});

    const cwd_dir_path = try std.fs.path.join(alloc, &.{ run_dir_path, "cwd" });
    try std.Io.Dir.cwd().createDirPath(self.daemon.io, cwd_dir_path);

    const script_path = try std.fs.path.join(alloc, &.{ run_dir_path, "bin" });
    const script_file = try std.Io.Dir.cwd().createFile(self.daemon.io, script_path, .{
        .permissions = .executable_file,
    });
    errdefer script_file.close(self.daemon.io);

    while (true)
        switch (try req.conn.recv_ref(null)) {
            .data => |data| try script_file.writeStreamingAll(self.daemon.io, data),
            .end => break,
            else => return error.SyntaxError,
        };
    script_file.close(self.daemon.io);
    try self.daemon.term.debug("wrote script: {s}", .{script_path});

    const output_dir_path = try std.fs.path.join(alloc, &.{ run_dir_path, "out" });

    var write_dirs = try alloc.alloc([]const u8, task.pipline.outputs.len + 1);
    for (task.pipline.outputs, 0..) |output, i| {
        const path = try std.fs.path.join(alloc, &.{
            output_dir_path,
            output.name,
        });
        try std.Io.Dir.cwd().createDirPath(self.daemon.io, path);
        write_dirs[i] = path;
    }
    write_dirs[write_dirs.len - 1] = cwd_dir_path;

    try self.daemon.term.info("starting systemd unit {s}", .{unit_name});

    var child = try systemd.run(
        alloc,
        self.daemon.io,
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
                .write = write_dirs,
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

    try self.daemon.term.success("task {s} started", .{task.pipline.name});
    try req.conn.send(.ok);

    return;
}
