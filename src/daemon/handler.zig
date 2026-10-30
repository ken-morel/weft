const std = @import("std");
const log = std.log.scoped;

const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const systemd = @import("../util/systemd.zig");
const zoto = @import("../util/zoto.zig");
const Connection = @import("../wire/Connection.zig");
const Packer = @import("../wire/Packer.zig");
const Pressor = @import("../wire/Pressor.zig");
const clinternal = @import("clinternal.zig");
const Daemon = @import("Daemon.zig");
const DaemonInstall = @import("DaemonInstall.zig");
const Server = @import("Server.zig");
const Task = @import("Task.zig");

const handlers = struct {
    const artifact = @import("./handler/artifact.zig");
    const task = @import("./handler/task.zig");
};

pub fn handle(daemon: *Daemon, permits: *std.Io.Semaphore, stream: std.Io.net.Stream) !void {
    const l = log(.client_server);
    defer permits.post(daemon.io);
    errdefer stream.close(daemon.io);

    _run(daemon, stream) catch |err| {
        if (err == error.ReAssigned)
            return;
        l.err("worker error: {any}", .{err});
        if (@errorReturnTrace()) |trace|
            std.debug.dumpErrorReturnTrace(trace);
    };

    stream.close(daemon.io);
}

fn _run(daemon: *Daemon, stream: std.Io.net.Stream) !void {
    const l = log(.client_server);
    var arena: std.heap.ArenaAllocator = .init(daemon.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const reader_buf = try alloc.alloc(u8, 4 << 10);
    const writer_buf = try alloc.alloc(u8, 4 << 10);

    var reader = stream.reader(daemon.io, reader_buf);
    var writer = stream.writer(daemon.io, writer_buf);

    var conn = try daemon.connect(
        &reader.interface,
        &writer.interface,
    );

    const request = request: {
        var req_buffer: [1 << 5]u8 = undefined;
        break :request conn.recv_object_buf(&req_buffer, proto.Request) catch |err|
            return if (err == error.BufferTooSmall)
                error.InvalidRequest
            else
                err;
    };

    const response_buf = try alloc.alloc(u8, 4 << 10);
    switch (request) {
        .artifact_push => {
            const res = handlers.artifact.push(daemon, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::artifact_push {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .task_spawn => {
            const res = handlers.task.spawn(daemon, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::task_spawn {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .artifact_pull => {
            const res = handlers.artifact.pull(daemon, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::artifact_pull {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .task_poll => {
            const res = handlers.task.poll(daemon, &conn, response_buf) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::task_poll {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .artifact_has => {
            const res = handlers.artifact.has(daemon, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::artifact_has {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
        .system_stats => {
            const req = try conn.recv_object_buf(response_buf, proto.system.stats.Req);
            try daemon.stats_server.add_listener(stream, req.from);
            return error.ReAssigned;
        },
        .task_kill => {
            const res = handlers.task.kill(daemon, &conn) catch |err| err: {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                l.err("daemon::worker::task_kill {any}", .{err});
                break :err err;
            };
            try conn.send_object(response_buf, @TypeOf(res), res);
        },
    }
}
