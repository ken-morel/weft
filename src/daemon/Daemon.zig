const Connection = @import("../Connection.zig");
const Server = @import("../Server.zig");
const std = @import("std");
const DaemonInstall = @import("../DaemonInstall.zig");
const Term = @import("../Term.zig");
const Worker = @import("Worker.zig");

io: std.Io,
alloc: std.mem.Allocator,
install: DaemonInstall,
server: Server,
config: DaemonInstall.Config,
term: *Term,

pub fn deinit(self: *@This()) void {
    self.server.deinit(self.io);
}
pub fn init(alloc: std.mem.Allocator, io: std.Io, install: DaemonInstall, term: *Term) !@This() {
    const config = try install.get_config(io, alloc, term);

    const server = try Server.init(
        io,
        &config.secret,
        config.port,
    );
    return .{
        .alloc = alloc,
        .io = io,
        .install = install,
        .config = config,
        .server = server,
        .term = term,
    };
}

pub fn run(self: *@This()) !void {
    try self.term.info("listening on TCP :{d} and Unix {s}", .{ self.config.port, Server.unix_socket_path });
    try self.term.debug("max workers: {d}", .{self.config.max_workers});

    var group: std.Io.Group = .init;
    defer group.cancel(self.io);

    const workers = try self.alloc.alloc(Worker, self.config.max_workers);
    var permits: std.Io.Semaphore = .{ .permits = self.config.max_workers };
    try self.term.debug("spawned {d} workers", .{workers.len});

    for (workers) |*worker|
        worker.* = try .init(self.alloc, self);

    while (true) {
        try permits.wait(self.io);

        const worker: *Worker = worker: for (workers) |*w| {
            if (!w.running)
                break :worker w;
        } else unreachable;
        worker.running = true;

        const req = req: while (true)
            break :req self.server.accept(worker.allocator.allocator(), self.io) catch |err| {
                if (err == error.Canceled)
                    return;
                try self.term.err("accept error: {any}", .{err});
                continue :req;
            };
        try self.term.info("new connection", .{});
        group.async(
            self.io,
            struct {
                fn do(do_worker: *Worker, do_permits: *std.Io.Semaphore, do_req: *Server.Request) void {
                    defer do_permits.post(do_worker.daemon.io);
                    defer do_worker.running = false;
                    do_worker.handle(do_req) catch |err| {
                        do_worker.daemon.term.err("worker error: {any}", .{err}) catch return;
                    };
                }
            }.do,
            .{ worker, &permits, req },
        );
    }
}
