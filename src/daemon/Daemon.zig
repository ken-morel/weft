const std = @import("std");

const Connection = @import("../Connection.zig");
const DaemonInstall = @import("../DaemonInstall.zig");
const Server = @import("../Server.zig");
const Term = @import("../Term.zig");
const SharedPressor = @import("SharedPressor.zig");
const Worker = @import("Worker.zig");

io: std.Io,
alloc: std.mem.Allocator,
install: DaemonInstall,
server: Server,
config: DaemonInstall.Config,
term: *Term,
pressor: SharedPressor,

pub fn deinit(self: *@This()) void {
    self.server.deinit(self.io);
    self.pressor.deinit(self.alloc);
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
        .pressor = try .init(alloc, io),
    };
}

pub fn run(self: *@This()) !void {
    try self.term.info("listening on TCP :{d}", .{self.config.port});
    try self.term.debug("max workers: {d}", .{self.config.max_workers});

    var group: std.Io.Group = .init;
    defer group.cancel(self.io);

    const workers = try self.alloc.alloc(Worker, self.config.max_workers);
    var permits: std.Io.Semaphore = .{ .permits = self.config.max_workers };
    try self.term.debug("spawned {d} workers", .{workers.len});

    for (workers) |*worker| {
        worker.* = try .init(try self.alloc.alignedAlloc(u8, comptime std.mem.Alignment.fromByteUnits(std.heap.page_size_min), Worker.worker_heap_mem), self);
    }

    while (true) {
        try permits.wait(self.io);

        const worker: *Worker = worker: for (workers) |*w| {
            if (!w.running)
                break :worker w;
        } else unreachable;
        worker.running = true;

        const stream: std.Io.net.Stream = req: while (true)
            break :req self.server.accept(self.io) catch |err| {
                if (err == error.Canceled)
                    return;
                try self.term.err("accept error: {any}", .{err});
                continue :req;
            };
        try self.term.info("new connection", .{});

        group.async(
            self.io,
            Worker.run,
            .{ worker, &permits, stream },
        );
    }
}
