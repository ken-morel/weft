const std = @import("std");
const log = std.log.scoped;

const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const zoto = @import("../util/zoto.zig");
const Task = @import("Task.zig");

pub fn reload_keys(io: std.Io) void {
    const l = log(.clinternal_reloadkeys);

    const addr: std.Io.net.UnixAddress = std.Io.net.UnixAddress.init(paths.weft_socket) catch |err| {
        l.debug("failed to initialize socket address {s}: {any}", .{ paths.weft_socket, err });
        return;
    };

    var stream = addr.connect(io) catch |err| {
        l.debug("daemon socket not available {s}: {any}", .{ paths.weft_socket, err });
        return;
    };
    defer stream.close(io);
    var writer_buf: [1 << 5]u8 = undefined;
    var writer = stream.writer(io, &writer_buf);

    zoto.serialize(
        &writer.interface,
        proto.DaemonMsg,
        .reload_keys,
        .{ .header = true },
    ) catch |err| {
        l.warn("failed to serialize reload keys message: {any}", .{err});
        return;
    };
    writer.interface.flush() catch |err| {
        l.warn("failed to flush reload keys notification: {any}", .{err});
        return;
    };
}
