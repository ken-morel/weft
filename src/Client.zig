const Connection = @import("Connection.zig");
const Server = @import("Server.zig");
const std = @import("std");

const Remote = @import("install/client.zig").Remote;

conn: Connection,
rw: struct { std.Io.net.Stream.Reader, std.Io.net.Stream.Writer },
rw_buffers: struct { []u8, []u8 },
stream: std.Io.net.Stream,

fn init(self: *@This(), alloc: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, secret: []const u8) !void {
    const reader_buf = try alloc.alloc(u8, 4 << 10);
    errdefer alloc.free(reader_buf);
    const writer_buf = try alloc.alloc(u8, 4 << 10);
    errdefer alloc.free(writer_buf);

    self.stream = stream;
    self.rw_buffers = .{ reader_buf, writer_buf };
    self.rw = .{ stream.reader(io, reader_buf), stream.writer(io, writer_buf) };
    self.conn = try Connection.init(
        alloc,
        io,
        secret,
        &self.rw.@"0".interface,
        &self.rw.@"1".interface,
    );
}

pub fn connect(alloc: std.mem.Allocator, io: std.Io, remote: Remote) !*@This() {
    return try connect_tcp(alloc, io, remote.address, remote.token);
}

pub fn connect_tcp(alloc: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, secret: []const u8) !*@This() {
    const stream = try addr.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    errdefer stream.close(io);
    const self = try alloc.create(@This());
    errdefer alloc.destroy(self);
    try self.init(alloc, io, stream, secret);
    return self;
}

pub fn connect_local(alloc: std.mem.Allocator, io: std.Io, secret: []const u8) !*@This() {
    return try connect_unix(alloc, io, secret, null);
}
pub fn connect_unix(alloc: std.mem.Allocator, io: std.Io, secret: []const u8, path: ?[]const u8) !*@This() {
    const socket_path = path orelse Server.unix_socket_path;
    const unix_addr = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try unix_addr.connect(io);
    errdefer stream.close(io);
    const self = try alloc.create(@This());
    errdefer alloc.destroy(self);
    try self.init(alloc, io, stream, secret);
    return self;
}

pub fn shutdown(self: *@This(), io: std.Io) void {
    self.stream.shutdown(io, .both) catch {};
}

pub fn destroy(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
    self.stream.close(io);
    self.conn.deinit(alloc);
    alloc.free(self.rw_buffers.@"0");
    alloc.free(self.rw_buffers.@"1");
    alloc.destroy(self);
}
