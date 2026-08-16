pub const unix_socket_path = "/run/weft/weft.sock";

secret: [32]u8,
tcp_listener: std.Io.net.Server,
unix_listener: std.Io.net.Server,
permits: std.Io.Semaphore,

pub const Request = struct {
    server: *Self,
    conn: Connection,
    stream: std.Io.net.Stream,
    rw_buffers: struct { []u8, []u8 },
    rw: struct { std.Io.net.Stream.Reader, std.Io.net.Stream.Writer },

    pub fn shutdown(self: *@This(), io: std.Io) void {
        self.stream.shutdown(io, .both) catch {};
    }

    fn initInPlace(self: *@This(), alloc: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, server: *Self) !void {
        const writer_buf = try alloc.alloc(u8, 4 << 10);
        errdefer alloc.free(writer_buf);
        const reader_buf = try alloc.alloc(u8, 4 << 10);
        errdefer alloc.free(reader_buf);

        self.rw_buffers = .{ reader_buf, writer_buf };
        self.rw = .{ stream.reader(io, reader_buf), stream.writer(io, writer_buf) };
        self.stream = stream;
        self.server = server;
        self.conn = try Connection.init(
            alloc,
            io,
            &server.secret,
            &self.rw.@"0".interface,
            &self.rw.@"1".interface,
        );
    }

    pub fn destroy(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
        self.stream.close(io);
        self.conn.deinit(alloc);
        self.server.permits.post(io);
        alloc.free(self.rw_buffers.@"0");
        alloc.free(self.rw_buffers.@"1");
        alloc.destroy(self);
    }
};

pub fn init(
    io: std.Io,
    secret: *const [32]u8,
    opts: struct {
        port: u16 = 9336,
        max_conn: u32 = 10,
    },
) !@This() {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", opts.port);
    const tcp_listener = try addr.listen(
        io,
        .{
            .kernel_backlog = @as(u31, @intCast(opts.max_conn)),
        },
    );
    errdefer tcp_listener.socket.close(io);

    std.Io.Dir.cwd().createDirPath(io, "/run/weft") catch |err|
        if (err != error.PathAlreadyExists)
            return err;

    std.Io.Dir.cwd().deleteFile(io, unix_socket_path) catch |err|
        if (err != error.FileNotFound)
            return err;

    const unix_addr = try std.Io.net.UnixAddress.init(unix_socket_path);
    const unix_listener = try unix_addr.listen(
        io,
        .{
            .kernel_backlog = @as(u31, @intCast(opts.max_conn)),
        },
    );

    return .{
        .tcp_listener = tcp_listener,
        .unix_listener = unix_listener,
        .secret = secret.*,
        .permits = .{ .permits = opts.max_conn },
    };
}

const AcceptResult = std.Io.net.Server.AcceptError!std.Io.net.Stream;

const AcceptUnion = union(enum) {
    tcp: AcceptResult,
    unix: AcceptResult,
};

pub fn accept(self: *@This(), alloc: std.mem.Allocator, io: std.Io) !*Request {
    try self.permits.wait(io);
    errdefer self.permits.post(io);

    var buf: [2]AcceptUnion = undefined;
    var sel = std.Io.Select(AcceptUnion).init(io, &buf);

    const accept_conn = struct {
        fn func(listener: *std.Io.net.Server, cio: std.Io) AcceptResult {
            return listener.accept(cio);
        }
    }.func;

    try sel.concurrent(.tcp, accept_conn, .{ &self.tcp_listener, io });
    try sel.concurrent(.unix, accept_conn, .{ &self.unix_listener, io });

    const winner = sel.await() catch |err| {
        sel.cancelDiscard();
        return err;
    };
    sel.cancelDiscard();

    const stream = switch (winner) {
        .tcp => |r| r,
        .unix => |r| r,
    } catch |err| return err;
    errdefer stream.close(io);

    const req = try alloc.create(Request);
    errdefer alloc.destroy(req);
    try req.initInPlace(alloc, io, stream, self);
    return req;
}

pub fn deinit(self: *@This(), io: std.Io) void {
    self.tcp_listener.deinit(io);
    self.unix_listener.deinit(io);
    std.Io.Dir.cwd().deleteFile(io, unix_socket_path) catch {};
}

const std = @import("std");
const Connection = @import("Connection.zig");
const Self = @This();
