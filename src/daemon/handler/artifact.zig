const std = @import("std");
const log = std.log.scoped;

const paths = @import("../../domain/paths.zig");
const proto = @import("../../domain/proto.zig");
const systemd = @import("../../util/systemd.zig");
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
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const alloc = arena.allocator();
    const io = daemon.io;

    const req = try conn.recv_object(alloc, proto.artifact.has.Req);
    const deployment = req.id.deployment.to_string();
    const artifact_dir_path = try paths.artifact(
        gpa,
        req.id.workspace,
        &deployment,
        req.id.pipeline,
    );
    defer gpa.free(artifact_dir_path);
    const res = has: {
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
    return .{ .has = res };
}

pub fn pull(daemon: *Daemon, conn: *Connection) proto.Res(proto.artifact.pull.Res) {
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req = try conn.recv_object(alloc, proto.artifact.pull.Req);
    const id = &req.id;

    const artifact_dir_path = try paths.artifact(
        alloc,
        id.workspace,
        &id.deployment.to_string(),
        id.pipeline,
    );

    try std.Io.Dir.cwd().access(
        daemon.io,
        artifact_dir_path,
        .{},
    );

    try transfer.push(gpa, daemon.io, conn, artifact_dir_path, daemon.config.compress, null);
    return .{};
}

pub fn push(daemon: *Daemon, conn: *Connection) proto.Res(proto.artifact.push.Res) {
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const alloc = arena.allocator();
    const req = try conn.recv_object(alloc, proto.artifact.push.Req);

    const artifact_dir_path = try paths.artifact(
        gpa,
        req.id.workspace,
        &req.id.deployment.to_string(),
        req.id.pipeline,
    );

    std.Io.Dir.cwd().deleteTree(daemon.io, artifact_dir_path) catch |err|
        if (err == error.Cancelled)
            return err;

    const temp_dir = try DaemonInstall.open_temp(daemon.io, "artifact");
    defer temp_dir.close(daemon.io);
    const temp_dir_path = try temp_dir.realPathFileAlloc(daemon.io, ".", alloc);

    try transfer.pull(gpa, daemon.io, conn, temp_dir_path, daemon.config.compress, null);

    if (std.fs.path.dirname(artifact_dir_path)) |parent|
        try std.Io.Dir.cwd().createDirPath(daemon.io, parent);
    try std.Io.Dir.cwd().rename(
        temp_dir_path,
        std.Io.Dir.cwd(),
        artifact_dir_path,
        daemon.io,
    );
    return .{};
}
