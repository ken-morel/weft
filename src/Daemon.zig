io: std.Io,
alloc: std.mem.Allocator,
install: DaemonInstall,
server: Server,
config: DaemonInstall.Config,
arena: std.heap.ArenaAllocator,

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
    self.server.deinit(self.io);
}
pub fn init(alloc: std.mem.Allocator, io: std.Io, install: DaemonInstall) !@This() {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const config = try install.get_config(io, &arena);

    const server = try Server.init(io, &config.secret, .{
        .port = config.port,
        .max_conn = config.max_conn,
    });
    return .{
        .alloc = alloc,
        .io = io,
        .install = install,
        .arena = arena,
        .config = config,
        .server = server,
    };
}

fn handle_conn(req: *Server.Request, alloc: std.mem.Allocator, io: std.Io) void {
    defer req.deinit(alloc, io);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const conn: *Connection = &req.conn;

    const msg = conn.recv(&arena) catch return;
    std.debug.print("message received: {any}", .{msg});
}

pub fn run(self: *@This()) !void {
    std.debug.print("Listening on TCP :{d} and Unix {s}\n", .{ self.config.port, Server.unix_socket_path });

    var group: std.Io.Group = .init;
    defer group.cancel(self.io);

    while (true) {
        const req = self.server.accept(self.alloc, self.io) catch |err| {
            if (err == error.Canceled) return;
            std.debug.print("accept error: {any}\n", .{err});
            continue;
        };
        group.async(
            self.io,
            handle_conn,
            .{ req, self.alloc, self.io },
        );
    }
}

const Connection = @import("Connection.zig");
const Server = @import("Server.zig");
const std = @import("std");
const DaemonInstall = @import("install.zig").Daemon;
