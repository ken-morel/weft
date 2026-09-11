const ids = @import("ids.zig");
const Task = @import("Task.zig");
const UUIDv7 = @import("UUIDv7.zig");
const Weft = @import("Weft.zig");

secret: [32]u8,
listener: std.Io.net.Server,

pub const Request = struct {
    pub const Message = union(enum(u8)) {
        artifact_push: struct {
            artifact_id: Task.Id,
        },
        artifact_pull: struct {
            artifact_id: Task.Id,
        },

        task_spawn: struct {
            task_spec: Task.Spec,
        },
        task_abort: struct {
            task_spec: Task.Spec,
        },
        task_status: struct {
            task_spec: Task.Spec,
        },

        task_logs_snapshot: struct {
            task_spec: Task.Spec,
        },
        task_logs_stream: struct {
            task_spec: Task.Spec,
        },
    };

    req: Message,
    server: *Server,
    conn: *Connection,
    stream: std.Io.net.Stream,

    //TODO: Find a better name which isn't deinit
    pub fn close(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
        self.stream.shutdown(io, .both) catch {};
        self.stream.close(io);
        self.conn.deinit(alloc);
    }
};

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

pub fn accept(self: *@This(), alloc: std.mem.Allocator, io: std.Io) !*Request {
    const stream = try self.listener.accept(io);
    errdefer stream.close(io);

    return try Request.create(alloc, io, stream, self);
}

pub fn deinit(self: *@This(), io: std.Io) void {
    self.listener.deinit(io);
}

const std = @import("std");
const Connection = @import("Connection.zig");
const Server = @This();
