const Connection = @import("../net/Connection.zig");
const Server = @import("../net/Server.zig");
const std = @import("std");
const DaemonInstall = @import("../install/daemon.zig");
const Term = @import("../util/Term.zig");
const handler = @import("handler.zig");

io: std.Io,
alloc: std.mem.Allocator,
install: DaemonInstall,
server: Server,
config: DaemonInstall.Config,
arena: std.heap.ArenaAllocator,
term: *Term,

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
    self.server.deinit(self.io);
}
pub fn init(alloc: std.mem.Allocator, io: std.Io, install: DaemonInstall, term: *Term) !@This() {
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
        .term = term,
    };
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
            handler.handle_conn,
            .{ self, req },
        );
    }
}
