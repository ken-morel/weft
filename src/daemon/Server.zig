const std = @import("std");

listener: std.Io.net.Server,

pub fn init(io: std.Io, port: u16) !@This() {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    const tcp_listener = try addr.listen(
        io,
        .{ .reuse_address = true },
    );
    errdefer tcp_listener.deinit(io);
    return .{
        .listener = tcp_listener,
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
