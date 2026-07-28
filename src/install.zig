// const std = @import("std");

const client_config_size_limit: std.Io.Limit = .limited(10 << 10);
pub const remotes_zon_file_name = "remotes.zon";

const std = @import("std");

pub const read_only_user_permissions = @as(std.Io.File.Permissions, @enumFromInt(@as(u32, std.os.linux.S.IRUSR | std.os.linux.S.IWUSR)));
pub const read_only_user_mode = read_only_user_permissions.toMode();

pub const Daemon = struct {
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
    pub const Config = struct {
        secret: [32]u8 = undefined,
        port: u16 = 9338,
        max_conn: u32 = 5,
    };

    pub fn init() !@This() {
        return .{};
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
        // create config
        var config = Config{};
        try io.randomSecure(&config.secret);

        // write cconfig to cconfig file

        var config_file = try cwd.createFileAtomic(io, "/etc/weft.zon", .{
            .permissions = read_only_user_permissions,
            .replace = true,
        });

        var write_buffer: [4 << 10]u8 = undefined;
        var config_writer = config_file.file.writer(io, &write_buffer);

        try std.zon.stringify.serialize(config, .{}, &config_writer.interface);
        try config_writer.interface.flush();

        try config_file.replace(io);

        // write systemd file

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
        try stdout.writeStreamingAll(io, "\n=== Weft Daemon Installed Successfully ===\nsecret: ");
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
            std.debug.print("FATAL: /etc/weft.zon has insecure permissions. Must be 0600.\n", .{});
            return error.InsecurePermissions;
        }
        var buff: [4 << 10]u8 = undefined;
        var reader = file.reader(io, &buff);
        const content = try reader.interface.allocRemaining(alloc, client_config_size_limit);
        defer alloc.free(content);
        const null_terminated = try alloc.dupeSentinel(u8, content, 0);

        return try std.zon.parse.fromSliceAlloc(Config, alloc, null_terminated, null, .{});
    }
};

pub const Client = struct {
    config_dir: std.Io.Dir,

    pub const Remote = struct {
        name: []const u8,
        address: []const u8 = "127.0.0.1",
        port: u16 = 9338,
        token: []const u8,
    };

    pub fn init(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !@This() {
        const config_dir = try Client.open_config_dir(alloc, io, env);
        const data_dir = try Client.open_data_dir(alloc, io, env);
        defer data_dir.close(io);

        return .{
            .config_dir = config_dir,
        };
    }

    pub fn open_config_dir(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !std.Io.Dir {
        const path = try if (env.get("XDG_CONFIG_HOME")) |xdg|
            std.fs.path.join(alloc, &.{ xdg, "weft" })
        else if (env.get("HOME")) |home|
            std.fs.path.join(alloc, &.{ home, ".config", "weft" })
        else
            return error.NoHomeFound;
        defer alloc.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
        return try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    }
    pub fn open_data_dir(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !std.Io.Dir {
        const path = try if (env.get("HOME")) |home|
            std.fs.path.join(alloc, &.{ home, ".weft" })
        else
            return error.NoHomeFound;
        defer alloc.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
        return try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    }

    pub fn get_remotes(self: @This(), arena: *std.heap.ArenaAllocator, io: std.Io) ![]Remote {
        const alloc = arena.allocator();
        const content = self.config_dir.readFileAlloc(
            io,
            remotes_zon_file_name,
            alloc,
            .unlimited,
        ) catch |err|
            return if (err == error.FileNotFound)
                &.{}
            else
                err;
        defer alloc.free(content);
        const null_terminated = try alloc.dupeSentinel(u8, content, 0);
        return std.zon.parse.fromSliceAlloc([]Remote, alloc, null_terminated, null, .{});
    }
    pub fn set_remotes(self: @This(), io: std.Io, remotes: []const Remote) !void {
        var atomic = try self.config_dir.createFileAtomic(io, remotes_zon_file_name, .{ .permissions = read_only_user_permissions, .replace = true });
        defer atomic.deinit(io);
        var buffer: [4 << 10]u8 = undefined;
        var writer = atomic.file.writer(io, &buffer);
        try std.zon.stringify.serialize(remotes, .{}, &writer.interface);
        try writer.flush();
        try atomic.replace(io);
    }
    pub fn add_remotes(self: @This(), alloc: std.mem.Allocator, io: std.Io, items: []const Remote) !void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        const aac = arena.allocator();
        const old_remotes = try self.get_remotes(&arena, io);
        const remotes = try aac.realloc(old_remotes, old_remotes.len + items.len);

        std.mem.copyForwards(Remote, remotes[old_remotes.len..], items);
        try self.set_remotes(io, remotes);
    }
};
