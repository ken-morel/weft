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

pub fn poll(
    daemon: *Daemon,
    conn: *Connection,
    response_buf: []u8,
) proto.Res(proto.task.poll.Res) {
    const l = log(.handle_task_poll);
    const cwd = std.Io.Dir.cwd();
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = daemon.io;
    const req = (try conn.recv_object(alloc, proto.task.poll.Req)).header;

    for (req.tasks) |item_req| {
        const task: Task = .{ .id = item_req.task };

        const archive_dir_path = task.archive_dir_path(
            alloc,
        ) catch |err|
            return err;

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

            const to_read = @min(size - offset, Connection.max_packet_size - (4 << 10));
            const buff = try alloc.alloc(u8, to_read);

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

pub fn kill(daemon: *Daemon, conn: *Connection) proto.Res(proto.task.kill.Res) {
    var arena: std.heap.ArenaAllocator = .init(daemon.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const req = try conn.recv_object(alloc, proto.task.kill.Req);
    const task: Task = .{ .id = .{
        .deployment = req.deployment,
        .pipeline = req.pipeline,
        .workspace = req.workspace,
    } };
    try task.kill(alloc, daemon.io);
    return .{};
}

pub fn spawn(daemon: *Daemon, conn: *Connection) proto.Res(proto.task.spawn.Res) {
    const l = log(.handle_task_spawn);
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const alloc = arena.allocator();
    const io = daemon.io;

    const spec = (try conn.recv_object(alloc, proto.task.spawn.Req)).spec;

    const task: Task = .{ .id = spec.task_id };
    const run_dir_path = try task.run_dir_path(alloc);
    const run_dir = try std.Io.Dir.cwd().createDirPathOpen(io, run_dir_path, .{});
    defer run_dir.close(io);

    try task.write_spec(gpa, daemon.io, spec);

    l.info("Wrote spec for task: {s}/spec", .{run_dir_path});

    try supervisor.fork(io, task.id);
    return .{};
}
