const std = @import("std");
const log = std.log.scoped;

const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const zoto = @import("../util/zoto.zig");
const Task = @import("Task.zig");

pub fn task_completed(alloc: std.mem.Allocator, io: std.Io, task: Task, status: u16) !void {
    const l = log(.clinternal_taskcompleted);
    const archive_path = try task.archive(alloc);
    defer alloc.free(archive_path);
    const archive_dir = try std.Io.Dir.cwd().openDir(io, archive_path, .{});
    defer archive_dir.close(io);

    {
        var atomic = try archive_dir.createFileAtomic(io, "status", .{ .replace = true });
        defer atomic.deinit(io);

        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, status, .little);
        try atomic.file.writeStreamingAll(io, &buf);

        try atomic.replace(io);
    }

    notify: {
        const addr: std.Io.net.UnixAddress = std.Io.net.UnixAddress.init(paths.weft_socket) catch |err| {
            l.warn("failed to initialize socket address {s}: {any}", .{ paths.weft_socket, err });
            break :notify;
        };

        var stream = addr.connect(io) catch |err| {
            l.warn("failed to connect to daemon socket {s}: {any}", .{ paths.weft_socket, err });
            break :notify;
        };
        defer stream.close(io);
        var writer_buf: [1 << 5]u8 = undefined;
        var writer = stream.writer(io, &writer_buf);

        zoto.serialize(
            &writer.interface,
            proto.DaemonMsg,
            .{ .task_completed = .{ .status = status, .task = task.id } },
            .{ .header = true },
        ) catch |err| {
            l.warn("failed to serialize task completed message: {any}", .{err});
            break :notify;
        };
        writer.interface.flush() catch |err| {
            l.warn("failed to flush task completed notification: {any}", .{err});
            break :notify;
        };
    }
}
