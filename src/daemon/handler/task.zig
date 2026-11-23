const std = @import("std");
const log = std.log.scoped;

const Deployment = @import("../../client/Deployment.zig");
const paths = @import("../../domain/paths.zig");
const proto = @import("../../domain/proto.zig");
const Task = @import("../../domain/Task.zig");
const supervisor = @import("../../supervisor/supervisor.zig");
const zoto = @import("../../util/zoto.zig");
const Connection = @import("../../wire/Connection.zig");
const Packer = @import("../../wire/Packer.zig");
const Pressor = @import("../../wire/Pressor.zig");
const clinternal = @import("../clinternal.zig");
const Daemon = @import("../Daemon.zig");
const DaemonInstall = @import("../DaemonInstall.zig");
const Server = @import("../Server.zig");

pub fn poll(daemon: *Daemon, conn: *Connection, response_buf: []u8) proto.R(proto.task.poll.Res) {
    const cwd: std.Io.Dir = .cwd();
    const gpa = daemon.gpa;

    var barena: std.heap.ArenaAllocator = .init(gpa);
    defer barena.deinit();
    const balloc = barena.allocator();

    const io = daemon.io;

    while (try conn.recv_object(balloc, proto.task.poll.Req)) |req| {
        defer _ = barena.reset(.free_all);

        const id = req.task;
        const task: Task = .{ .id = id };

        const status = task.read_status(gpa, io) catch |err|
            if (err == error.FileNotFound) {
                try conn.send_object(
                    response_buf,
                    proto.R(proto.task.poll.Res),
                    .{
                        .task = req.task,
                        .logs = null,
                        .status = null,
                        .usage = null,
                    },
                );
                continue;
            } else return err;

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
                    .more = 0,
                };

            const to_read = @min(size - offset, 3 << 10);
            const buff = try balloc.alloc(u8, to_read);

            _ = try logs_file.readPositionalAll(io, buff, offset);
            const end_offset = offset + to_read;
            break :read_logs .{
                .data = buff,
                .end_offset = end_offset,
                .more = size -| end_offset,
            };
        } else null;

        const usage: ?proto.task.poll.TaskUsage = try task.usage(gpa, io);

        try conn.send_object(response_buf, proto.R(proto.task.poll.Res), .{
            .task = req.task,
            .logs = logs,
            .status = status,
            .usage = usage,
        });
    }

    return null;
}

pub fn kill(daemon: *Daemon, conn: *Connection) proto.R(proto.task.kill.Res) {
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

fn _cmp_deployment_gt(_: void, a: Deployment.Id, b: Deployment.Id) bool {
    return a.gt(b);
}

fn apply_retention(gpa: std.mem.Allocator, io: std.Io, spec: Task.Spec) !void {
    const l = log(.task_retention);
    const cwd: std.Io.Dir = .cwd();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const task: Task = .{ .id = spec.id };

    prune_tasks: {
        const keep_count: usize = if (spec.retention.archive > 0)
            spec.retention.archive - 1
        else
            0;
        const task_path = try gpa.print(paths.task, task.id.wpd());
        defer gpa.free(task_path);
        const task_dir_path = std.fs.path.dirname(task_path) orelse unreachable;

        var parent_dir = cwd.openDir(
            io,
            task_dir_path,
            .{ .iterate = true },
        ) catch |err|
            if (err == error.FileNotFound)
                break :prune_tasks
            else
                return err;
        defer parent_dir.close(io);

        var ids: std.ArrayList(Deployment.Id) = .empty;
        var iter = parent_dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .directory)
                continue;
            const dep_id = try Deployment.Id.parse(entry.name);
            if (dep_id.eq(spec.id.deployment))
                continue;
            try ids.append(alloc, dep_id);
        }

        std.mem.sort(Deployment.Id, ids.items, {}, _cmp_deployment_gt);

        if (ids.items.len > keep_count)
            for (ids.items[keep_count..]) |old_id| {
                const old_task: Task = .{ .id = .{
                    .workspace = spec.id.workspace,
                    .pipeline = spec.id.pipeline,
                    .deployment = old_id,
                } };
                if (try old_task.is_active(gpa, io))
                    continue;

                const name = old_id.to_string();
                l.debug("pruning old task dir {s}{s}", .{ task_dir_path, &name });
                parent_dir.deleteTree(io, &name) catch |err|
                    l.warn("failed to prune task dir {s}{s}: {any}", .{ task_dir_path, &name, err });
                const link_path = try gpa.print(paths.active_link, old_task.id.wpd());
                defer gpa.free(link_path);
                cwd.deleteFile(io, link_path) catch {};
            };
    }

    const keep_artifacts: usize = spec.retention.artifacts -| 1;

    for (spec.outputs) |output| {
        const artifact_path = try gpa.print(paths.artifact, task.id.w_d(output));
        defer gpa.free(artifact_path);
        const parent_path = std.fs.path.dirname(artifact_path) orelse unreachable;

        var parent_dir = cwd.openDir(io, parent_path, .{ .iterate = true }) catch |err|
            if (err != error.FileNotFound)
                return err
            else
                continue;
        defer parent_dir.close(io);

        var ids: std.ArrayList(Deployment.Id) = .empty;
        var iter = parent_dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .directory)
                continue;
            const dep_id = try Deployment.Id.parse(entry.name);
            if (dep_id.eq(spec.id.deployment))
                continue;
            try ids.append(alloc, dep_id);
        }

        std.mem.sort(Deployment.Id, ids.items, {}, _cmp_deployment_gt);

        if (ids.items.len > keep_artifacts)
            for (ids.items[keep_artifacts..]) |old_id| {
                const name = old_id.to_string();
                l.debug("pruning old artifact dir {s}{s}", .{ parent_path, &name });
                parent_dir.deleteTree(io, &name) catch |err|
                    l.warn("failed to prune artifact dir {s}{s}: {any}", .{ parent_path, &name, err });
            };
    }
}

pub fn spawn(daemon: *Daemon, conn: *Connection) proto.R(proto.task.spawn.Res) {
    const l = log(.handle_task_spawn);
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const spec = (try conn.recv_object(alloc, proto.task.spawn.Req)).spec;

    const task: Task = .{ .id = spec.id };

    l.info("spawning task {s}/{s}/{d}", .{ task.id.workspace, task.id.pipeline, task.id.deployment });

    try apply_retention(gpa, daemon.io, spec);

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

    var timeout: i16 = 60;
    return while (timeout >= 0) : (timeout -= 1)
        if (task.read_status(gpa, daemon.io)) |_|
            break .{}
        else |e| if (e == error.Canceled)
            break e
        else
            try daemon.io.sleep(.fromSeconds(1), .awake)
    else
        error.SpawnTimedout;
}
