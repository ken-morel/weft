const std = @import("std");
const log = std.log.scoped;

const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const format_duration = @import("../util/sizes.zig").format_duration;
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
    const cache = @import("./handler/cache.zig");
    const task = @import("./handler/task.zig");
};

pub fn handle(daemon: *Daemon, permits: *std.Io.Semaphore, stream: std.Io.net.Stream) !void {
    const l = log(.client_server);
    defer permits.post(daemon.io);
    errdefer stream.close(daemon.io);

    _run(daemon, stream) catch |err| {
        if (err == error.ReAssigned or err == error.EndOfStream)
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

    const response_buf = try alloc.alloc(u8, 4 << 10);

    while (true) {
        var req_buffer: [1 << 5]u8 = undefined;
        const request = conn.recv_object_buf(&req_buffer, proto.Request) catch |err| {
            if (err == error.EndOfStream)
                return;
            return if (err == error.BufferTooSmall)
                error.InvalidRequest
            else
                err;
        };

        const t_start = std.Io.Clock.now(.real, daemon.io);
        l.debug("request: {any}", .{request});

        switch (request) {
            .artifact_push => {
                const res = handlers.artifact.push(daemon, &conn) catch |err| err: {
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    l.err("artifact_push failed: {any}", .{err});
                    break :err err;
                };
                try conn.send_object(response_buf, @TypeOf(res), res);
            },
            .task_spawn => {
                const res = handlers.task.spawn(daemon, &conn) catch |err| err: {
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    l.err("task_spawn failed: {any}", .{err});
                    break :err err;
                };
                try conn.send_object(response_buf, @TypeOf(res), res);
            },
            .artifact_pull => {
                const res = handlers.artifact.pull(daemon, &conn) catch |err| err: {
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    l.err("artifact_pull failed: {any}", .{err});
                    break :err err;
                };
                try conn.send_object(response_buf, @TypeOf(res), res);
            },
            .task_poll => {
                const res = handlers.task.poll(daemon, &conn, response_buf) catch |err| err: {
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    l.err("task_poll failed: {any}", .{err});
                    break :err err;
                };
                try conn.send_object(response_buf, @TypeOf(res), res);
            },
            .artifact_has => {
                const res = handlers.artifact.has(daemon, &conn) catch |err| err: {
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    l.err("artifact_has failed: {any}", .{err});
                    break :err err;
                };
                try conn.send_object(response_buf, @TypeOf(res), res);
            },
            .cache_push => {
                const res = handlers.cache.push(daemon, &conn) catch |err| err: {
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    l.err("cache_push failed: {any}", .{err});
                    break :err err;
                };
                try conn.send_object(response_buf, @TypeOf(res), res);
            },
            .cache_pull => {
                const res = handlers.cache.pull(daemon, &conn) catch |err| err: {
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    l.err("cache_pull failed: {any}", .{err});
                    break :err err;
                };
                try conn.send_object(response_buf, @TypeOf(res), res);
            },
            .cache_has => {
                const res = handlers.cache.has(daemon, &conn) catch |err| err: {
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    l.err("cache_has failed: {any}", .{err});
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
                    l.err("task_kill failed: {any}", .{err});
                    break :err err;
                };
                try conn.send_object(response_buf, @TypeOf(res), res);
            },
        }

        if (request != .system_stats) {
            const t_end = std.Io.Clock.now(.real, daemon.io);
            const dur = t_start.durationTo(t_end);
            var dur_buf: [32]u8 = undefined;
            l.info("{s} handled in {s}", .{ @tagName(request), format_duration(&dur_buf, dur.nanoseconds) });
        }
    }
}
