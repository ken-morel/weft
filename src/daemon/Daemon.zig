const std = @import("std");

const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const zoto = @import("../util/zoto.zig");
const Connection = @import("../wire/Connection.zig");
const DaemonInstall = @import("DaemonInstall.zig");
const Server = @import("Server.zig");
const SharedPressor = @import("SharedPressor.zig");
const Task = @import("Task.zig");
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
    std.zon.parse.free(self.alloc, self.config);
}
pub fn init(alloc: std.mem.Allocator, io: std.Io, install: DaemonInstall, term: *Term) !@This() {
    const config = try install.get_config(io, alloc, term);

    const server = try Server.init(
        io,
        &try config.get_secret(),
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

pub fn run_client_server(self: *@This()) void {
    _run_client_server(self) catch |err| {
        if (err == error.Canceled)
            return;
        if (@errorReturnTrace()) |trace|
            std.debug.dumpErrorReturnTrace(trace);
    };
}
pub fn _run_client_server(self: *@This()) !void {
    self.term.info("listening on TCP :{d}", .{self.config.port});

    var group: std.Io.Group = .init;
    defer group.cancel(self.io);

    const workers = try self.alloc.alloc(Worker, self.config.max_workers);
    var permits: std.Io.Semaphore = .{ .permits = self.config.max_workers };
    self.term.debug("spawned {d} workers", .{workers.len});

    for (workers) |*worker|
        worker.* = try .init(self.alloc, self);

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
                self.term.err("accept error: {any}", .{err});
                continue :req;
            };
        self.term.info("new connection", .{});

        group.async(
            self.io,
            Worker.run,
            .{ worker, &permits, stream },
        );
    }
}

pub fn run_system_server(self: *@This()) void {
    while (true) {
        _run_system_server(self) catch |err| {
            if (err == error.Canceled)
                return;
            self.term.err("Error: {any}", .{err});
            if (@errorReturnTrace()) |trace|
                std.debug.dumpErrorReturnTrace(trace);
        };
        break;
    }
}

pub fn _run_system_server(self: *@This()) !void {
    var group: std.Io.Group = .init;
    defer group.cancel(self.io);

    defer std.Io.Dir.deleteFileAbsolute(self.io, paths.weft_socket) catch {};

    std.Io.Dir.cwd().createDirPath(self.io, paths.weft_dir) catch {};

    const addr: std.Io.net.UnixAddress = try .init(paths.weft_socket);
    std.Io.Dir.deleteFileAbsolute(self.io, paths.weft_socket) catch |err|
        if (err != error.FileNotFound)
            return err;

    var srv = try addr.listen(self.io, .{});

    var buff: [4 << 10]u8 = undefined;

    var conn: std.Io.net.Stream = undefined;
    var reader: std.Io.net.Stream.Reader = undefined;

    const Run = union(enum) {
        accept,
        read_cmd,
        done,
        invalid_request: []const u8,
    };
    self.term.info("listening on socket {s}", .{paths.weft_socket});
    var req_arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer req_arena.deinit();
    run: switch (@as(Run, .accept)) {
        // accept
        .accept => {
            conn = try srv.accept(self.io);
            reader = conn.reader(self.io, &buff);
            continue :run .read_cmd;
        },
        .read_cmd => {
            reader.interface.readSliceAll(&buff) catch |err| {
                if (err != error.EndOfStream)
                    return err;
            };
            var slice: []const u8 = &buff;
            const cmd = try zoto.deserialize(
                null,
                &slice,
                proto.DaemonMsg,
                .{ .header = true },
            );
            self.term.info("daemon cmd: {any}", .{cmd});
            switch (cmd) {
                .task_completed => |msg| {
                    group.async(self.io, finalize_task, .{ self, Task{ .id = try msg.task.dupe(self.alloc) }, msg.status });
                    continue :run .done;
                },
            }
        },
        // replies
        .invalid_request => |msg| {
            self.term.err("  invalid request: {s}", .{msg});
            conn.close(self.io);
        },
        .done => {
            conn.close(self.io);
            _ = req_arena.reset(.free_all);
            continue :run .accept;
        },
    }
}

pub fn run(self: *@This()) !void {
    self.term.debug("max workers: {d}", .{self.config.max_workers});
    _ = std.Io.async(self.io, run_client_server, .{self});

    self.run_system_server();
}

pub fn finalize_task(self: *@This(), task: Task, status: u16) void {
    _finalize_task(self, task, status) catch |err| {
        self.term.err("finalize task error: {any}", .{err});
        if (@errorReturnTrace()) |trace|
            std.debug.dumpErrorReturnTrace(trace);
    };
    task.free_duped(self.alloc) catch {};
}
pub fn _finalize_task(self: *@This(), task: Task, status: u16) !void {
    _ = status;
    const cwd = std.Io.Dir.cwd();
    const run_dir_path = try task.run_dir_path(self.alloc);
    defer self.alloc.free(run_dir_path);

    const run_dir = cwd.openDir(self.io, run_dir_path, .{}) catch |err|
        return if (err == error.FileNotFound) error.TaskNotFound else err;
    defer run_dir.close(self.io);
    defer cwd.deleteTree(self.io, run_dir_path) catch {};

    const output_dirs_path = try std.fs.path.join(self.alloc, &.{ run_dir_path, "out" });
    defer self.alloc.free(output_dirs_path);

    const artifacts_dir_path = try task.artifacts_path(self.alloc);
    defer self.alloc.free(artifacts_dir_path);
    const artifacts_dir = try cwd.createDirPathOpen(self.io, artifacts_dir_path, .{});
    defer artifacts_dir.close(self.io);

    const outputs_dir = try cwd.openDir(self.io, output_dirs_path, .{ .iterate = true });
    defer outputs_dir.close(self.io);

    var outputs: std.ArrayList([]const u8) = .empty;
    defer {
        for (outputs.items) |name|
            self.alloc.free(name);
        outputs.deinit(self.alloc);
    }
    var walker = try std.Io.Dir.walkSelectively(
        outputs_dir,
        self.alloc,
    );
    defer walker.deinit();
    while (try walker.next(self.io)) |entry|
        try outputs.append(self.alloc, try self.alloc.dupe(u8, entry.basename));

    for (outputs.items) |name|
        //TODO: maybe chown the artifacts to root
        try outputs_dir.rename(name, artifacts_dir, name, self.io);
}
