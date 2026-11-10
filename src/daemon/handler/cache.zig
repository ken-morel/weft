const std = @import("std");
const log = std.log.scoped;

const paths = @import("../../domain/paths.zig");
const proto = @import("../../domain/proto.zig");
const transfer = @import("../../wire/transfer.zig");
const Connection = @import("../../wire/Connection.zig");
const Daemon = @import("../Daemon.zig");

pub fn has(daemon: *Daemon, conn: *Connection) proto.Res(proto.cache.has.Res) {
    const l = log(.handle_cache_has);
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = daemon.io;

    const req = try conn.recv_object(alloc, proto.cache.has.Req);
    l.debug("has cache {s}/{s}?", .{ req.id.workspace, req.id.name });

    const cache_path = try alloc.print(paths.keep, .{ req.id.workspace, req.id.name });
    return if (std.Io.Dir.cwd().access(io, cache_path, .{})) |_|
        .{ .has = true }
    else |err| if (err == error.FileNotFound)
        .{ .has = false }
    else
        err;
}

pub fn pull(daemon: *Daemon, conn: *Connection) proto.Res(proto.cache.pull.Res) {
    const l = log(.handle_cache_pull);
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req = try conn.recv_object(alloc, proto.cache.pull.Req);

    l.info("pulling cache {s}/{s}", .{ req.id.workspace, req.id.name });

    const cache_path = try alloc.print(paths.keep, .{ req.id.workspace, req.id.name });
    try std.Io.Dir.cwd().access(
        daemon.io,
        cache_path,
        .{},
    );
    try transfer.push(gpa, daemon.io, conn, cache_path, daemon.config.scale.compress, null);
    return .{};
}

pub fn push(daemon: *Daemon, conn: *Connection) proto.Res(proto.cache.push.Res) {
    const l = log(.handle_cache_push);
    const gpa = daemon.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const req = try conn.recv_object(alloc, proto.cache.push.Req);

    l.info("pushing cache {s}/{s}", .{ req.id.workspace, req.id.name });

    const cwd: std.Io.Dir = .cwd();

    const cache_path = try alloc.print(paths.keep, .{ req.id.workspace, req.id.name });
    const temp_cache_path = try alloc.print(paths.workspace ++ "keep/tmp.{s}/", .{ req.id.workspace, req.id.name });

    if (std.fs.path.dirname(cache_path)) |parent|
        try cwd.createDirPath(daemon.io, parent);

    cwd.deleteTree(daemon.io, temp_cache_path) catch |err|
        if (err == error.Canceled)
            return err;

    try transfer.pull(gpa, daemon.io, conn, temp_cache_path, daemon.config.scale.decompress, null);

    cwd.deleteTree(daemon.io, cache_path) catch |err|
        if (err == error.Canceled)
            return err;

    try cwd.rename(
        temp_cache_path,
        cwd,
        cache_path,
        daemon.io,
    );
    return .{};
}
