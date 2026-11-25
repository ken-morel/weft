const std = @import("std");
const log = std.log.scoped;

const domain = @import("../domain/domain.zig");
const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const Task = @import("../domain/Task.zig");
const supervisor = @import("../supervisor/supervisor.zig");
const CGroup2 = @import("../util/CGroup2.zig");
const zoto = @import("../util/zoto.zig");
const Connection = @import("../wire/Connection.zig");
const Crypt = @import("../wire/Crypt.zig");
const DaemonInstall = @import("DaemonInstall.zig");
const handler = @import("handler.zig");
const Server = @import("Server.zig");
const StatsServer = @import("StatsServer.zig");

io: std.Io,
gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
install: DaemonInstall,
server: Server,
config: DaemonInstall.Config,
stats_server: StatsServer,
keys: [][32]u8,
keys_lock: std.Io.Mutex,

pub fn deinit(self: *@This()) void {
    self.gpa.free(self.keys);
    self.server.deinit(self.io);
    self.stats_server.deinit();
    self.arena.deinit();
}
pub fn init(gpa: std.mem.Allocator, io: std.Io, install: DaemonInstall) !@This() {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const config = try DaemonInstall.read_config(alloc, io);

    var server = try Server.init(
        io,
        config.port,
    );
    errdefer server.deinit(io);

    const keys = try DaemonInstall.get_keys(gpa, io);
    errdefer gpa.free(keys);

    return .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .install = install,
        .config = config,
        .server = server,
        .stats_server = try .init(gpa, io),
        .keys = keys,
        .keys_lock = .init,
    };
}

pub fn validate_key(self: *@This(), key: [32]u8) bool {
    self.keys_lock.lockUncancelable(self.io);
    defer self.keys_lock.unlock(self.io);
    return for (self.keys) |vkey| {
        if (std.crypto.timing_safe.eql([32]u8, key, vkey))
            break true;
    } else false;
}

pub fn reload(self: *@This()) !void {
    const l = log(.daemon_keys);
    const new_keys = try DaemonInstall.get_keys(self.gpa, self.io);
    self.keys_lock.lockUncancelable(self.io);
    defer self.keys_lock.unlock(self.io);
    self.gpa.free(self.keys);
    self.keys = new_keys;
    self.config = try DaemonInstall.read_config(self.arena.allocator(), self.io);
    l.info("Daemon reloaded", .{});
}

pub fn run_client_server(self: *@This()) !void {
    const l = log(.client_server);
    l.info("listening on TCP :{d}", .{self.config.port});

    var group: std.Io.Group = .init;
    defer group.cancel(self.io);

    var permits: std.Io.Semaphore = .{ .permits = self.config.scale.max_workers };

    while (true) {
        try permits.wait(self.io);

        const stream: std.Io.net.Stream = req: while (true)
            break :req self.server.accept(self.io) catch |err| {
                if (err == error.Canceled)
                    return;
                l.err("accept error: {any}", .{err});
                try std.Io.sleep(self.io, .fromMilliseconds(100), .awake);
                continue :req;
            };

        _ = try spawn(self.io, &group, handler.handle, .{ self, &permits, stream });
    }
}

pub fn run_system_server(self: *@This()) !void {
    while (true) {
        self._run_system_server() catch |err| {
            if (err == error.Canceled)
                return err
            else {
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
                log(.system_server).err("system server recoverable error: {any}", .{err});
            }
        };
    }
}
pub fn _run_system_server(self: *@This()) !void {
    const l = log(.system_server);
    var group: std.Io.Group = .init;
    defer group.cancel(self.io);

    defer std.Io.Dir.deleteFileAbsolute(self.io, paths.weft_socket) catch {};

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
            l.info("received command: {any}", .{cmd});
            switch (cmd) {
                .reload => {
                    self.reload() catch |err|
                        l.err("failed to reload keys: {any}", .{err});
                    continue :run .done;
                },
            }
        },
        .invalid_request => |msg| {
            l.err("invalid request: {s}", .{msg});
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
    l.info("received {s}, shutting down", .{@tagName(sig)});

    std.process.exit(0);
}

fn recover_active_tasks(self: *@This()) !void {
    const l = log(.respawn_active);
    var active_dir = std.Io.Dir.cwd().openDir(self.io, paths.weft_active, .{ .iterate = true }) catch |err| {
        l.warn("could not open {s}: {any}", .{ paths.weft_active, err });
        return err;
    };
    defer active_dir.close(self.io);

    var spec_arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer spec_arena.deinit();

    var iter = active_dir.iterate();
    while (try iter.next(self.io)) |entry| {
        defer _ = spec_arena.reset(.retain_capacity);

        var link_buf: [std.posix.PATH_MAX]u8 = undefined;
        const link_len = active_dir.readLink(self.io, entry.name, &link_buf) catch continue;

        const tid = Task.Id.from_task_dir(link_buf[0..link_len]) orelse {
            l.warn("removing unparseable active symlink '{s}'", .{entry.name});
            active_dir.deleteFile(self.io, entry.name) catch {};
            continue;
        };

        const task: Task = .{ .id = tid };
        const status = task.read_status(self.gpa, self.io) catch |err| {
            l.warn("removing dead active symlink '{s}' (status unreadable: {any})", .{ entry.name, err });
            active_dir.deleteFile(self.io, entry.name) catch {};
            continue;
        };

        switch (status) {
            .done, .skipped, .failed, .killed, .not_found => {
                l.info("removing dead active symlink '{s}' (status: {s})", .{ entry.name, @tagName(status) });
                active_dir.deleteFile(self.io, entry.name) catch {};
            },
            .preparing, .running, .harvesting, .frozen => {
                const running = task.is_active(self.gpa, self.io) catch false;
                if (running)
                    continue;

                const spec = task.read_spec(self.gpa, spec_arena.allocator(), self.io) catch |err| {
                    l.warn("task '{s}' is inactive and spec unreadable ({any}); removing dead symlink", .{ entry.name, err });
                    task.write_status(self.gpa, self.io, .killed) catch {};
                    active_dir.deleteFile(self.io, entry.name) catch {};
                    continue;
                };

                if (spec.restartable) {
                    l.info("respawning inactive restartable task {s}/{s}/{d}", .{ tid.workspace, tid.pipeline, tid.deployment });
                    supervisor.spawn_supervisor(
                        self.gpa,
                        self.io,
                        task.id,
                        self.config.isolate,
                    ) catch |err|
                        l.err("failed to respawn task {s}/{s}/{d}: {any}", .{ tid.workspace, tid.pipeline, tid.deployment, err });
                } else {
                    l.info("task {s}/{s}/{d} is inactive and not restartable; marking killed and removing symlink", .{ tid.workspace, tid.pipeline, tid.deployment });
                    task.write_status(self.gpa, self.io, .killed) catch {};
                    active_dir.deleteFile(self.io, entry.name) catch {};
                }
            },
        }
    }
}

pub fn run(self: *@This()) !void {
    _ = std.os.linux.syscall3(.setpriority, 0, 0, 10);
    const cwd: std.Io.Dir = .cwd();
    const l = log(.daemon);
    const pid = std.os.linux.getpid();
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\n", .{pid}) catch unreachable;
    try cwd.createDirPath(self.io, paths.weft_run);
    try domain.write_file_atomic(self.io, cwd, paths.weft_pid, pid_str, .{ .replace = true });
    defer std.Io.Dir.cwd().deleteFile(self.io, paths.weft_pid) catch {};

    try paths.ensure_dirs(self.io);
    DaemonInstall.setup_bin(self.gpa, self.io) catch |err|
        l.warn("could not setup bin dir: {any}", .{err});

    if (self.config.isolate.cgroups) init_cgroup: {
        var root_cg = CGroup2.init_absolute_take("/sys/fs/cgroup");
        for ([_][]const u8{ "+cpu", "+memory", "+io", "+pids" }) |ctrl|
            try root_cg.subtree_control_set(self.gpa, self.io, ctrl);

        var weft_cg = CGroup2.init(self.gpa, "weft") catch break :init_cgroup;
        defer weft_cg.deinit(self.gpa);
        weft_cg.create(self.io) catch |err|
            l.warn("could not create /sys/fs/cgroup/weft: {any}", .{err});
        for ([_][]const u8{ "+cpu", "+memory", "+io", "+pids" }) |ctrl|
            try weft_cg.subtree_control_set(self.gpa, self.io, ctrl);
    }
    try self.recover_active_tasks();

    var group: std.Io.Group = .init;

    _ = try spawn(self.io, &group, run_client_server, .{self});
    _ = try spawn(self.io, &group, StatsServer.run, .{&self.stats_server});
    _ = try spawn(self.io, &group, run_system_server, .{self});

    l.info("starting on port {d} (pid {d})", .{ self.config.port, std.os.linux.getpid() });
    defer l.info("stopped", .{});

    try group.await(self.io);
}

pub fn connect(self: *@This(), reader: *std.Io.Reader, writer: *std.Io.Writer) !Connection {
    const l = log(.client_server);
    var hello: Crypt.ClientHello = undefined;
    try reader.readSliceAll(std.mem.asBytes(&hello));
    if (!std.mem.eql(u8, &hello.magic, &Crypt.magick))
        return error.InvalidProtocol;

    if (!self.validate_key(hello.client_public)) {
        l.warn("rejecting client: key not authorized", .{});
        var reject_msg: Crypt.ServerChallenge = .{
            .status = .unauthorized,
            .challenge = undefined,
            .server_nonce = undefined,
            .server_temp_pub = undefined,
        };
        try writer.writeAll(std.mem.asBytes(&reject_msg));
        try writer.flush();
        return error.ClientUnauthorized;
    }

    var challenge: [32]u8 = undefined;
    try self.io.randomSecure(&challenge);
    const temp_dh = std.crypto.dh.X25519.KeyPair.generate(self.io);
    const out_nonce = try Crypt.Nonce.random(self.io);

    const challenge_msg: Crypt.ServerChallenge = .{
        .status = .ok,
        .challenge = challenge,
        .server_temp_pub = temp_dh.public_key,
        .server_nonce = out_nonce.to_bytes(),
    };
    try writer.writeAll(std.mem.asBytes(&challenge_msg));
    try writer.flush();

    var auth: Crypt.ClientAuth = undefined;
    try reader.readSliceAll(std.mem.asBytes(&auth));

    const sign_data = Crypt.make_sign_data(&challenge, &temp_dh.public_key);
    Crypt.Identity.verify(hello.client_public, &sign_data, auth.signature) catch
        return error.AuthenticationFailed;

    const shared_secret = try std.crypto.dh.X25519.scalarmult(
        temp_dh.secret_key,
        hello.client_temp_pub,
    );

    var in_nonce_bytes = hello.client_nonce;
    const in_nonce = try Crypt.Nonce.from_bytes(&in_nonce_bytes);

    return .{
        .reader = reader,
        .writer = writer,
        .write_crypt = .init(&shared_secret, out_nonce),
        .read_crypt = .init(&shared_secret, in_nonce),
    };
}
