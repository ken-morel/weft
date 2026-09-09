const Connection = @import("../Connection.zig");
const Server = @import("../Server.zig");
const std = @import("std");
const DaemonInstall = @import("../DaemonInstall.zig");
const Term = @import("../Term.zig");
const handler = @import("handler.zig");
const Worker = @import("Worker.zig");
const packer = @import("../packer.zig");

const max_worker_mem = 1 << 20;

alloc: std.heap.FixedBufferAllocator,
io: std.Io,
permit: std.Io.Semaphore,
running: bool,
term: *Term,

pub fn init(alloc: std.mem.Allocator, io: std.Io, term: *Term) @This() {
    return .{
        .alloc = .init(try alloc.alloc(u8, max_worker_mem)),
        .io = io,
        .term = term,
    };
}

pub fn run(self: *@This(), req: *Server.Request, permits: *std.Io.Semaphore) void {
    defer permits.post(self.io);
    defer self.alloc.reset();
    defer req.destroy(self.alloc, self.io);

    const msg = req.conn.recv_ref(
        null,
    ) catch |err|
        return if (err == error.EndOfStream)
            null
        else
            err;

    try self.term.printlnf(":{any}", .{msg});

    switch (msg) {
        .request => |r| switch (r) {
            .artifact_push => try self.handle_artifact_push(req),
            .task_spawn => try self.handle_task_spawn(req),
            else => {},
        },
        else => return error.InvalidRequest,
    }
}
fn handle_artifact_push(self: *@This(), req: *Server.Request) !void {
    try self.term.printlnf("    artifact push: ", .{});
    const conn = &req.conn;

    var temp_arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer temp_arena.deinit();
    var arena: std.heap.ArenaAllocator = .init(self.alloc);

    const artifact_id = switch (try conn.recv_dupe(arena)) {
        .artifact_id => |art_id| art_id,
        else => return error.SyntaxEror,
    };

    const artifact_dir_path = try std.fs.path.join(self.alloc, &.{
        "/var/lib/weft/artifacts",
        artifact_id.service.workspace,
        artifact_id.service.workspace,
        artifact_id.env,
        artifact_id.deployment,
        artifact_id.pipeline,
    });
    defer alloc.free(artifact_dir_path);

    const has_artifact = blk: {
        std.Io.Dir.cwd().access(
            self.io,
            artifact_dir_path,
            .{},
        ) catch |err|
            if (err == error.FileNotFound)
                break :blk false
            else
                return err;
        break :blk true;
    };
    try conn.send(.{ .bool = has_artifact });
    try self.term.printlnf("Sent has_artifact: {any}", .{has_artifact});
    if (has_artifact)
        return;

    const temp_dir = try self.install.open_temp(self.io, "artifact");
    defer temp_dir.close(self.io);

    const temp_dir_path = try temp_dir.realPathFileAlloc(self.io, ".", alloc);
    defer alloc.free(temp_dir_path);

    {
        var unpacker: *packer.Unpacker = try .init(alloc, temp_dir);
        defer unpacker.destroy(alloc, self.io);

        while (true) {
            const pack = try conn.recv_dupe(&temp_arena);
            switch (pack) {
                .folder => |folder| try unpacker.folder(self.io, folder),
                .file => |file| try unpacker.file(self.io, file),
                .data => |data| try unpacker.chunk(self.io, data),
                .end => break,
                else => return error.SyntaxError,
            }
            _ = temp_arena.reset(.retain_capacity);
        }
    }

    if (std.fs.path.dirname(artifact_dir_path)) |parent|
        std.Io.Dir.cwd().createDirPath(self.io, parent) catch {};
    try std.Io.Dir.cwd().rename(temp_dir_path, std.Io.Dir.cwd(), artifact_dir_path, self.io);
    try conn.send(.{ .ok = {} });
}

// tasks
// $IN ->  dir with / symlinks

// setup build env:
// - setup input artifacts as readonly.
// - $IN to /var/lib/weft/artifacts/{w}/{s}/{e}/{d} ($IN/pipeline gives artifact)
//
// - $OUT to /var/lib/weft/run/{w}/{s}/{e}/{d}/{p}/out/{a}
// - cwd to /var/lib/weft/run/{w}/{s}/{e}/{d}/{p}/cwd

pub fn handle_task_spawn(self: *@This(), arena: *std.heap.ArenaAllocator, req: *Server.Request) !void {
    try self.term.printlnf("  task spawn", .{});
    const conn = &req.conn;
    const alloc = arena.allocator();

    var msg_arena: std.heap.ArenaAllocator = .init(alloc);
    defer msg_arena.deinit();

    const task = switch (try conn.recv_dupe(arena)) {
        .task_spec => |spec| spec,
        else => return error.SyntaxEror,
    };

    const deployment = task.deployment.to_string();
    const service_name = try std.mem.join(alloc, "--", &.{
        "weft-runner",
        task.workspace,
        task.env,
        task.service,
        task.pipline,
        &deployment,
    });
    defer alloc.free(service_name);
    const input_dir = try std.fs.path.join(alloc, &.{ "/var/lib/weft/artifacts/", task.workspace, task.service, task.env, &deployment });
    defer alloc.free(input_dir);

    return;
}
