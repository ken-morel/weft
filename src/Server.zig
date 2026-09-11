const ids = @import("ids.zig");
const Task = @import("Task.zig");
const UUIDv7 = @import("UUIDv7.zig");
const Weft = @import("Weft.zig");

secret: [32]u8,
listener: std.Io.net.Server,

pub fn init(
    io: std.Io,
    secret: *const [32]u8,
    port: u16,
) !@This() {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    const tcp_listener = try addr.listen(
        io,
        .{},
    );
    errdefer tcp_listener.deinit(io);
    return .{
        .listener = tcp_listener,
        .secret = secret.*,
    };
}

pub fn accept(self: *@This(), io: std.Io) !std.Io.net.Stream {
    const stream = try self.listener.accept(io);
    errdefer stream.close(io);
    return stream;
}

pub fn deinit(self: *@This(), io: std.Io) void {
    self.listener.deinit(io);
}

const std = @import("std");
const Connection = @import("Connection.zig");
const Server = @This();
