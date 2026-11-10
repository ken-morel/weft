const std = @import("std");

const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const Connection = @import("../wire/Connection.zig");
const transfer = @import("../wire/transfer.zig");
const View = @import("View.zig");

pub fn pull_dir(
    gpa: std.mem.Allocator,
    io: std.Io,
    conn: *Connection,
    task_id: proto.task.Id,
    dir_path: []const u8,
    view: *View,
    remote_name: []const u8,
    artifact: []const u8,
) !void {
    const conn_buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(conn_buffer);

    try conn.send_object(conn_buffer, proto.Request, .artifact_pull);
    try conn.send_object(
        conn_buffer,
        proto.artifact.pull.Req,
        .{ .id = task_id },
    );

    var status: transfer.Status = .init;

    var group: std.Io.Group = .init;

    try spawn(io, &group, transfer.pull, .{ gpa, io, conn, dir_path, true, &status });

    {
        errdefer group.cancel(io);
        while (!status.done) : (try io.sleep(.fromMilliseconds(100), .awake))
            try view.set_transfer(io, artifact, remote_name, .pulling, progress(&status));
    }
    try group.await(io);
    if (status.err) |err|
        return err;

    _ = try try conn.recv_object_buf(conn_buffer, proto.Res(proto.artifact.pull.Res));
    try view.set_transfer(io, artifact, remote_name, .ready, 1.0);
}

pub fn push_dir(
    gpa: std.mem.Allocator,
    io: std.Io,
    conn: *Connection,
    task_id: proto.task.Id,
    dir_path: []const u8,
    view: *View,
    remote_name: []const u8,
    artifact: []const u8,
) !void {
    const conn_buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(conn_buffer);

    try conn.send_object(conn_buffer, proto.Request, .artifact_push);
    try conn.send_object(conn_buffer, proto.artifact.push.Req, .{ .id = task_id });

    var status: transfer.Status = .init;

    var group: std.Io.Group = .init;
    try spawn(io, &group, transfer.push, .{ gpa, io, conn, dir_path, true, &status });

    {
        errdefer group.cancel(io);
        while (!status.done) : (try io.sleep(.fromMilliseconds(100), .awake))
            try view.set_transfer(io, artifact, remote_name, .pushing, progress(&status));
    }
    try group.await(io);
    if (status.err) |err|
        return err;

    _ = try try conn.recv_object_buf(conn_buffer, proto.Res(proto.artifact.push.Res));
    try view.set_transfer(io, artifact, remote_name, .ready, 1.0);
}

pub fn pull_cache(
    gpa: std.mem.Allocator,
    io: std.Io,
    conn: *Connection,
    cache_id: proto.cache.Id,
    dir_path: []const u8,
    view: *View,
    remote_name: []const u8,
    cache_name: []const u8,
) !void {
    const conn_buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(conn_buffer);

    try conn.send_object(conn_buffer, proto.Request, .cache_pull);
    try conn.send_object(
        conn_buffer,
        proto.cache.pull.Req,
        .{ .id = cache_id },
    );

    var status: transfer.Status = .init;
    var group: std.Io.Group = .init;

    try spawn(io, &group, transfer.pull, .{ gpa, io, conn, dir_path, true, &status });

    {
        errdefer group.cancel(io);
        while (!status.done) : (try io.sleep(.fromMilliseconds(100), .awake))
            try view.set_transfer(io, cache_name, remote_name, .pulling, progress(&status));
    }
    try group.await(io);
    if (status.err) |err|
        return err;

    _ = try try conn.recv_object_buf(conn_buffer, proto.Res(proto.cache.pull.Res));
    try view.set_transfer(io, cache_name, remote_name, .ready, 1.0);
}

pub fn push_cache(
    gpa: std.mem.Allocator,
    io: std.Io,
    conn: *Connection,
    cache_id: proto.cache.Id,
    dir_path: []const u8,
    view: *View,
    remote_name: []const u8,
    cache_name: []const u8,
) !void {
    const conn_buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(conn_buffer);

    try conn.send_object(conn_buffer, proto.Request, .cache_push);
    try conn.send_object(conn_buffer, proto.cache.push.Req, .{ .id = cache_id });

    var status: transfer.Status = .init;
    var group: std.Io.Group = .init;
    try spawn(io, &group, transfer.push, .{ gpa, io, conn, dir_path, true, &status });

    {
        errdefer group.cancel(io);
        while (!status.done) : (try io.sleep(.fromMilliseconds(100), .awake))
            try view.set_transfer(io, cache_name, remote_name, .pushing, progress(&status));
    }
    try group.await(io);
    if (status.err) |err|
        return err;

    _ = try try conn.recv_object_buf(conn_buffer, proto.Res(proto.cache.push.Res));
    try view.set_transfer(io, cache_name, remote_name, .ready, 1.0);
}

fn progress(status: *const transfer.Status) f32 {
    if (status.done)
        return 1.0;
    if (status.total == 0)
        return 0.0;
    const file_ratio: f32 = if (status.file_total > 0)
        @as(f32, @floatFromInt(status.file_sent)) / @as(f32, @floatFromInt(status.file_total))
    else
        0.0;
    const files_done: f32 = if (status.sent > 0)
        @as(f32, @floatFromInt(status.sent - 1))
    else
        0.0;
    const total_float: f32 = @floatFromInt(status.total);
    return std.math.clamp((files_done + file_ratio) / total_float, 0.0, 1.0);
}
