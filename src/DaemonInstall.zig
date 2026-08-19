const std = @import("std");
const ClientInstall = @import("ClientInstall.zig");

const read_only_user_permissions = ClientInstall.read_only_user_permissions;
const read_only_user_mode = ClientInstall.read_only_user_mode;
const client_config_size_limit: std.Io.Limit = .limited(10 << 10);
const ids = @import("ids.zig");
const UUIDv7 = @import("UUIDv7.zig");

pub const Config = struct {
    secret: [32]u8 = undefined,
    port: u16 = 9338,
    max_conn: u32 = 5,
};

temp_dir: std.Io.Dir,

const service_template =
    \\[Unit]
    \\Description=Weft Deployment and Orchestration Daemon
    \\After=network.target
    \\
    \\[Service]
    \\Type=simple
    \\ExecStart=/usr/local/bin/weft daemon
    \\Restart=always
    \\User=root
    \\WorkingDirectory=/var/lib/weft
    \\
    \\[Install]
    \\WantedBy=multi-user.target
;

pub fn init(io: std.Io) !@This() {
    std.Io.Dir.cwd().createDirPath(io, "/tmp/weft") catch {};
    return .{
        .temp_dir = try std.Io.Dir.cwd().openDir(io, "/tmp/weft", .{}),
    };
}

pub fn open_temp(self: @This(), io: std.Io, sub: []const u8) !std.Io.Dir {
    var uuid_buf: [36]u8 = undefined;
    const uuid = try (try UUIDv7.now(io)).to_string(&uuid_buf);

    self.temp_dir.createDirPath(io, sub) catch {};
    var sub_dir = try self.temp_dir.openDir(io, sub, .{});
    defer sub_dir.close(io);

    try sub_dir.createDirPath(io, uuid);
    return try sub_dir.openDir(io, uuid, .{});
}

pub fn install(io: std.Io, alloc: std.mem.Allocator) !void {
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, "/var/lib/weft/workspaces");

    const exe_path = try std.process.executablePathAlloc(io, alloc);
    defer alloc.free(exe_path);

    if (!std.mem.eql(u8, exe_path, "/usr/local/bin/weft")) {
        const bin_dir = try cwd.openDir(io, "/usr/local/bin", .{});
        defer bin_dir.close(io);

        try cwd.copyFile(exe_path, bin_dir, "weft", io, .{});
    }

    var config = Config{};
    try io.randomSecure(&config.secret);

    var config_file = try cwd.createFileAtomic(io, "/etc/weft.zon", .{
        .permissions = read_only_user_permissions,
        .replace = true,
    });

    var write_buffer: [4 << 10]u8 = undefined;
    var config_writer = config_file.file.writer(io, &write_buffer);

    try std.zon.stringify.serialize(config, .{}, &config_writer.interface);
    try config_writer.interface.flush();

    try config_file.replace(io);

    const systemd_dir = try cwd.openDir(io, "/etc/systemd/system", .{});
    defer systemd_dir.close(io);

    var service_file = try systemd_dir.createFile(io, "weftd.service", .{});
    defer service_file.close(io);

    try service_file.writeStreamingAll(io, service_template);

    var child_sdr = try std.process.spawn(io, .{
        .argv = &.{ "systemctl", "daemon-reload" },
    });
    _ = try child_sdr.wait(io);

    var child_en = try std.process.spawn(io, .{
        .argv = &.{ "systemctl", "enable", "--now", "weftd.service" },
    });
    _ = try child_en.wait(io);

    const hex_key = std.fmt.bytesToHex(config.secret, .upper);

    var stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(
        io,
        "\n=== Weft Daemon Installed Successfully ===\nsecret: ",
    );
    try stdout.writeStreamingAll(io, &hex_key);
}

pub fn get_config(self: @This(), io: std.Io, arena: *std.heap.ArenaAllocator) !Config {
    _ = self;
    const alloc = arena.allocator();
    const cwd = std.Io.Dir.cwd();

    var file = cwd.openFile(io, "/etc/weft.zon", .{}) catch |err| {
        std.debug.print("FATAL: Daemon configuration missing. Run 'weft install-daemon' first.\n", .{});
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);

    if ((stat.permissions.toMode() & 0o777) != read_only_user_mode) {
        std.debug.print(
            "FATAL: /etc/weft.zon has insecure permissions. Must be 0600.\n",
            .{},
        );
        return error.InsecurePermissions;
    }
    var buff: [4 << 10]u8 = undefined;
    var reader = file.reader(io, &buff);
    const content = try reader.interface.allocRemaining(
        alloc,
        client_config_size_limit,
    );
    defer alloc.free(content);
    const null_terminated = try alloc.dupeSentinel(
        u8,
        content,
        0,
    );

    return try std.zon.parse.fromSliceAlloc(
        Config,
        alloc,
        null_terminated,
        null,
        .{},
    );
}

pub fn get_artifact_dir_path(
    self: @This(),
    alloc: std.mem.Allocator,
    art: ids.ArtifactId,
) ![]const u8 {
    _ = self;
    var uuid_buf: [36]u8 = undefined;
    const uuid = try art.deployment.to_string(&uuid_buf);
    return try std.fs.path.join(alloc, &.{
        "/var/lib/weft/artifacts/",
        art.service.workspace,
        uuid,
        art.service.name,
    });
}
pub fn open_artifact_dir(
    self: @This(),
    alloc: std.mem.Allocator,
    io: std.Io,
    art: ids.ArtifactId,
) !std.Io.Dir {
    const path = try self.get_artifact_dir_path(alloc, art);
    defer alloc.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return try std.Io.Dir.cwd().openDir(io, path, .{
        .iterate = true,
    });
}
