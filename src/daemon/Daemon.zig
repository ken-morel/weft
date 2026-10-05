const std = @import("std");
const log = std.log.scoped;

const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const zoto = @import("../util/zoto.zig");
const Connection = @import("../wire/Connection.zig");
const DaemonInstall = @import("DaemonInstall.zig");
const handler = @import("handler.zig");
const Server = @import("Server.zig");
const SharedPressor = @import("SharedPressor.zig");
const StatsServer = @import("StatsServer.zig");
const Store = @import("Store.zig");
const Task = @import("Task.zig");

io: std.Io,
gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
install: DaemonInstall,
server: Server,
config: DaemonInstall.Config,
pressor: SharedPressor,
stats_server: StatsServer,
store: Store,

pub fn deinit(self: *@This()) void {
    self.server.deinit(self.io);
    self.pressor.deinit(self.gpa);
    self.stats_server.deinit();
    self.store.deinit();
    self.arena.deinit();
}
pub fn init(gpa: std.mem.Allocator, io: std.Io, install: DaemonInstall) !@This() {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const config = try DaemonInstall.read_config_leaky(io, alloc);

    var server = try Server.init(
        io,
        &try config.get_secret(),
        config.port,
    );
    errdefer server.deinit(io);
    return .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .install = install,
        .config = config,
        .server = server,
        .pressor = try .init(gpa, io),
        .stats_server = try .init(gpa, io),
        .store = .init(gpa),
    };
}

pub fn run_client_server(self: *@This()) !void {
    const log_a = log(.client_server);
    log_a.info("listening on TCP :{d}", .{self.config.port});

    var group: std.Io.Group = .init;
    defer group.cancel(self.io);

    var permits: std.Io.Semaphore = .{ .permits = self.config.max_workers };

    while (true) {
        try permits.wait(self.io);

        const stream: std.Io.net.Stream = req: while (true)
            break :req self.server.accept(self.io) catch |err| {
                if (err == error.Canceled)
                    return;
                log_a.err("accept error: {any}", .{err});
                std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch {};
                continue :req;
            };

        try spawn(self.io, &group, handler.handle, .{ self, &permits, stream });
    }
}

pub fn run_system_server(self: *@This()) !void {
    const l = log(.system_server);
    var group: std.Io.Group = .init;
    defer group.cancel(self.io);

    defer std.Io.Dir.deleteFileAbsolute(self.io, paths.weft_socket) catch {};

    std.Io.Dir.cwd().createDirPath(self.io, paths.weft_runtime_dir) catch {};

    const addr: std.Io.net.UnixAddress = try .init(paths.weft_socket);
    std.Io.Dir.deleteFileAbsolute(self.io, paths.weft_socket) catch |err|
        if (err != error.FileNotFound)
            return err;

    var srv = try addr.listen(self.io, .{});
    defer srv.deinit(self.io);

    var buff: [4 << 10]u8 = undefined;

    var conn: std.Io.net.Stream = undefined;
    var reader: std.Io.net.Stream.Reader = undefined;

    const Run = union(enum) {
        accept,
        read_cmd,
        done,
        invalid_request: []const u8,
    };
    l.info("listening on socket {s}", .{paths.weft_socket});
    var req_arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer req_arena.deinit();
    run: switch (@as(Run, .accept)) {
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
            l.info("daemon cmd: {any}", .{cmd});
            switch (cmd) {
                .task_completed => |msg| {
                    try spawn(self.io, &group, finalize_task, .{ self, Task{ .id = try msg.task.dupe(self.gpa) }, msg.status });
                    continue :run .done;
                },
            }
        },
        .invalid_request => |msg| {
            l.err("  invalid request: {s}", .{msg});
            conn.close(self.io);
        },
        .done => {
            conn.close(self.io);
            _ = req_arena.reset(.free_all);
            continue :run .accept;
        },
    }
}

fn handle_signal(sig: std.posix.SIG) callconv(.c) void {
    const l = log(.handle_signal);
    l.warn("Someone wanted to push us with a {any}, but we're still exiting gracefuly...", .{sig});

    std.process.exit(0);
}

pub fn run(self: *@This()) !void {
    paths.ensure_dirs(self.io);

    var group: std.Io.Group = .init;

    try spawn(self.io, &group, run_client_server, .{self});
    try spawn(self.io, &group, StatsServer.run, .{&self.stats_server});
    try spawn(self.io, &group, run_system_server, .{self});

    try group.await(self.io);
}

pub fn finalize_task(self: *@This(), task: Task, status: u16) !void {
    const l = log(.task_finalize);
    defer task.free_duped(self.gpa);
    const cwd = std.Io.Dir.cwd();
    const run_dir_path = try task.run_dir_path(self.gpa);
    defer self.gpa.free(run_dir_path);

    const run_dir = cwd.openDir(self.io, run_dir_path, .{}) catch |err|
        return if (err == error.FileNotFound) error.TaskNotFound else err;
    defer run_dir.close(self.io);
    defer cwd.deleteTree(self.io, run_dir_path) catch {};

    if (status != 0) {
        l.warn("task {s} failed with exit code {d}, skipping artifact promotion", .{ task.id.pipeline, status });
        return;
    }

    const output_dirs_path = try std.fs.path.join(self.gpa, &.{ run_dir_path, "out" });
    defer self.gpa.free(output_dirs_path);

    const artifacts_dir_path = try task.artifacts_path(self.gpa);
    defer self.gpa.free(artifacts_dir_path);
    const artifacts_dir = try cwd.createDirPathOpen(self.io, artifacts_dir_path, .{});
    defer artifacts_dir.close(self.io);

    const outputs_dir = cwd.openDir(self.io, output_dirs_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer outputs_dir.close(self.io);

    var outputs: std.ArrayList([]const u8) = .empty;
    defer {
        for (outputs.items) |name|
            self.gpa.free(name);
        outputs.deinit(self.gpa);
    }
    var it = outputs_dir.iterate();
    while (try it.next(self.io)) |entry|
        try outputs.append(self.gpa, try self.gpa.dupe(u8, entry.name));

    for (outputs.items) |name| {
        artifacts_dir.deleteTree(self.io, name) catch {};
        try outputs_dir.rename(name, artifacts_dir, name, self.io);
    }
}
