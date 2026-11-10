const std = @import("std");
const log = std.log.scoped;

const paths = @import("../../domain/paths.zig");
const proto = @import("../../domain/proto.zig");
const supervisor = @import("../../supervisor/supervisor.zig");
const zoto = @import("../../util/zoto.zig");
const Connection = @import("../../wire/Connection.zig");
const Packer = @import("../../wire/Packer.zig");
const Pressor = @import("../../wire/Pressor.zig");
const clinternal = @import("../clinternal.zig");
const Daemon = @import("../Daemon.zig");
const DaemonInstall = @import("../DaemonInstall.zig");
const Server = @import("../Server.zig");
const Task = @import("../Task.zig");

pub fn poll(daemon: *Daemon, conn: *Connection, response_buf: []u8) proto.Res(proto.task.poll.Res) {
    const l = log(.handle_task_poll);
    const cwd: std.Io.Dir = .cwd();
    const gpa = daemon.gpa;

    var barena: std.heap.ArenaAllocator = .init(gpa);
    defer barena.deinit();
    const balloc = barena.allocator();

    const io = daemon.io;

    while (try conn.recv_object(balloc, proto.task.poll.Req)) |req| {
        defer _ = barena.reset(.free_all);

        const id = req.task;
        l.debug("poll {s}/{s}/{d}", .{ id.workspace, id.pipeline, id.deployment }); //debug
        const task: Task = .{ .id = id };

        const status = task.read_status(gpa, io) catch |err|
            if (err == error.FileNotFound) {
                try conn.send_object(
                    response_buf,
                    proto.Res(proto.task.poll.Res),
                    .{
                        .task = req.task,
                        .logs = null,
                        .status = null,
                        .usage = null,
                    },
                );
                continue;
            } else return err;

        l.debug("status: {s}", .{@tagName(status)}); //debug

        const logs: ?proto.task.poll.Logs = if (req.logs_offset) |offset| read_logs: {
            const logs_file = cwd.openFile(
                io,
                try balloc.print(paths.task_log, id.wpd()),
                .{},
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
                    .end_offset = size,
                };

            const to_read = @min(size - offset, 3 << 10);
            const buff = try balloc.alloc(u8, to_read);

            _ = try logs_file.readPositionalAll(io, buff, offset);
            break :read_logs .{
                .data = buff,
                .end_offset = offset + to_read,
            };
        } else null;

        const usage: ?proto.task.poll.TaskUsage = try task.usage(gpa, io);

        try conn.send_object(response_buf, proto.Res(proto.task.poll.Res), .{
            .task = req.task,
            .logs = logs,
            .status = status,
            .usage = usage,
        });
    }

    return null;
}

pub fn kill(daemon: *Daemon, conn: *Connection) proto.Res(proto.task.kill.Res) {
    const l = log(.handle_task_kill);
    var arena: std.heap.ArenaAllocator = .init(daemon.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const req = try conn.recv_object(alloc, proto.task.kill.Req);
    l.info("killing task {s}/{s}/{d}", .{ req.workspace, req.pipeline, req.deployment });
    const task: Task = .{ .id = .{
        .deployment = req.deployment,
        .pipeline = req.pipeline,
        .workspace = req.workspace,
    } };
    try task.kill(alloc, daemon.io);
    l.debug("kill request complete", .{}); //debug
    return .{};
}

pub fn spawn(daemon: *Daemon, conn: *Connection) proto.Res(proto.task.spawn.Res) {
    const l = log(.handle_task_spawn);
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const alloc = arena.allocator();

    const spec = (try conn.recv_object(alloc, proto.task.spawn.Req)).spec;

    const task: Task = .{ .id = spec.task_id };

    l.info("spawning task {s}/{s}/{d}", .{ task.id.workspace, task.id.pipeline, task.id.deployment });

    const task_dir = try gpa.print(paths.task, task.id.wpd());
    defer gpa.free(task_dir);
    try std.Io.Dir.cwd().createDirPath(daemon.io, task_dir);
    l.debug("created task dir {s}", .{task_dir}); //debug

    const status_path = try gpa.print(paths.task_status, task.id.wpd());
    defer gpa.free(status_path);
    std.Io.Dir.cwd().deleteFile(daemon.io, status_path) catch {};

    const log_path = try gpa.print(paths.task_log, task.id.wpd());
    defer gpa.free(log_path);
    std.Io.Dir.cwd().deleteFile(daemon.io, log_path) catch {};

    try task.write_spec(gpa, daemon.io, spec);
    l.debug("spec written", .{}); //debug

    try supervisor.spawn_supervisor(gpa, daemon.io, task.id, daemon.config.isolate);
    l.debug("supervisor spawned", .{}); //debug

    var timeout: i16 = 30;
    return while (timeout >= 0) : (timeout -= 1)
        if (task.read_status(gpa, daemon.io)) |_|
            break .{}
        else |e| if (e == error.Canceled)
            return e
        else
            try daemon.io.sleep(.fromSeconds(1), .awake)
    else
        return error.SpawnTimedout;
}
