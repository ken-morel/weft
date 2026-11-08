const std = @import("std");
const log = std.log.scoped;

const paths = @import("../../domain/paths.zig");
const proto = @import("../../domain/proto.zig");
const zoto = @import("../../util/zoto.zig");
const Connection = @import("../../wire/Connection.zig");
const Packer = @import("../../wire/Packer.zig");
const Pressor = @import("../../wire/Pressor.zig");
const transfer = @import("../../wire/transfer.zig");
const clinternal = @import("../clinternal.zig");
const Daemon = @import("../Daemon.zig");
const DaemonInstall = @import("../DaemonInstall.zig");
const Server = @import("../Server.zig");
const Task = @import("../Task.zig");

pub fn has(daemon: *Daemon, conn: *Connection) proto.Res(proto.artifact.has.Res) {
    const l = log(.handle_artifact_has);
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const alloc = arena.allocator();
    const io = daemon.io;

    const req = try conn.recv_object(alloc, proto.artifact.has.Req);
    l.debug("has {s}/{s}/{d}?", .{ req.id.workspace, req.id.pipeline, req.id.deployment }); //debug

    return if (std.Io.Dir.cwd().access(
        io,
        try alloc.print(paths.artifact, req.id.wpd()),
        .{},
    )) |_|
        .{ .has = true }
    else |err| if (err == error.FileNotFound)
        .{ .has = false }
    else
        err;
}

pub fn pull(daemon: *Daemon, conn: *Connection) proto.Res(proto.artifact.pull.Res) {
    const l = log(.handle_artifact_pull);
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req = try conn.recv_object(alloc, proto.artifact.pull.Req);

    l.debug("pulling artifact {s}/{s}/{d}", .{ req.id.workspace, req.id.pipeline, req.id.deployment }); //debug

    const artifact_path = try alloc.print(paths.artifact, req.id.wpd());
    try std.Io.Dir.cwd().access(
        daemon.io,
        artifact_path,
        .{},
    );
    try transfer.push(gpa, daemon.io, conn, artifact_path, daemon.config.scale.compress, null);
    return .{};
}

pub fn push(daemon: *Daemon, conn: *Connection) proto.Res(proto.artifact.push.Res) {
    const l = log(.handle_artifact_push);
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const alloc = arena.allocator();
    const req = try conn.recv_object(alloc, proto.artifact.push.Req);

    l.info("pushing artifact {s}/{s}/{d}", .{ req.id.workspace, req.id.pipeline, req.id.deployment });

    const cwd: std.Io.Dir = .cwd();

    const artifact_path = try alloc.print(paths.artifact, req.id.wpd());
    const temp_artifact_path = try alloc.print(paths.artifact_tmp, req.id.wpd());

    if (std.fs.path.dirname(artifact_path)) |parent|
        try cwd.createDirPath(daemon.io, parent);

    cwd.deleteTree(daemon.io, temp_artifact_path) catch |err|
        if (err == error.Canceled)
            return err;

    try transfer.pull(gpa, daemon.io, conn, temp_artifact_path, daemon.config.scale.decompress, null);

    //BUG: The artifact won't be available for a fracton of a second if it was already existing
    cwd.deleteTree(daemon.io, artifact_path) catch |err|
        if (err == error.Canceled)
            return err;

    try cwd.rename(
        temp_artifact_path,
        cwd,
        artifact_path,
        daemon.io,
    );
    return .{};
}
