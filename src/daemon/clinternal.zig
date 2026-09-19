const std = @import("std");

const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const zoto = @import("../util/zoto.zig");
const Task = @import("Task.zig");

pub fn task_completed(alloc: std.mem.Allocator, io: std.Io, term: *Term, task: Task, status: u16) !void {
    _ = term;
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

    {
        const addr: std.Io.net.UnixAddress = try .init(paths.weft_socket);

        var stream = try addr.connect(io);
        defer stream.close(io);
        var writer_buf: [1 << 5]u8 = undefined;
        var writer = stream.writer(io, &writer_buf);

        try zoto.serialize(
            &writer.interface,
            proto.DaemonMsg,
            .{ .task_completed = .{ .status = status, .task = task.id } },
            .{ .header = true },
        );
        try writer.interface.flush();
    }
}
