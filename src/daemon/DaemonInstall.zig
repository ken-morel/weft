const std = @import("std");
const log = std.log.scoped;

const ClientInstall = @import("../client/ClientInstall.zig");
const read_only_user_permissions = ClientInstall.read_only_user_permissions;
const Deployment = @import("../client/Deployment.zig");
const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");

pub const Config = struct {
    runner_user: ?[]const u8 = null,
    port: u16 = 9338,
    max_workers: u32 = 8,
    max_nix_workers: u32 = 5,
};

const service_template =
    \\[Unit]
    \\Description=Weft Deployment and Orchestration Daemon
    \\After=network.target
    \\
    \\[Service]
    \\Type=simple
    \\ExecStart=/usr/local/bin/weft daemon run
    \\Restart=always
    \\User=root
    \\WorkingDirectory=/var/lib/weft
    \\RuntimeDirectory=weft
    \\RuntimeDirectoryMode=0700
    \\
    \\[Install]
    \\WantedBy=multi-user.target
;

const sysusers_config_path = "/usr/lib/sysusers.d/weft.conf";
const sysusers_config =
    \\ u weft-runner - "Weft pipeline runner" /var/lib/weft /usr/bin/nologin
;

pub fn init(_: std.Io) !@This() {
    return .{};
}

pub fn open_temp(io: std.Io, sub: []const u8) !std.Io.Dir {
    const uuid = (try Deployment.Id.now(io)).to_string();

    var tmp_dir = try std.Io.Dir.cwd().createDirPathOpen(
        io,
        paths.weft_tmp_dir,
        .{ .open_options = .{} },
    );
    defer tmp_dir.close(io);

    try tmp_dir.createDirPath(io, sub);
    var sub_dir = try tmp_dir.createDirPathOpen(io, sub, .{});
    defer sub_dir.close(io);

    return try sub_dir.createDirPathOpen(io, &uuid, .{ .open_options = .{ .iterate = true } });
}

pub fn install(io: std.Io, gpa: std.mem.Allocator, maybe_user: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cwd = std.Io.Dir.cwd();

    var child_stop = try std.process.spawn(io, .{
        .argv = &.{ "systemctl", "stop", "weftd.service" },
    });
    const stop_term = try child_stop.wait(io);
    if (stop_term != .exited or stop_term.exited != 0)
        return error.SystemctlStopFailed;

    install_exe: {
        const exe_path = try std.process.executablePathAlloc(io, alloc);

        if (!std.mem.eql(u8, exe_path, "/usr/local/bin/weft")) {
            const bin_dir = try cwd.openDir(io, "/usr/local/bin", .{});
            defer bin_dir.close(io);

            try cwd.copyFile(exe_path, bin_dir, "weft", io, .{});
        }
        break :install_exe;
    }

    log(.daemon_install).debug("installed binary to /usr/local/bin/weft", .{});

    write_config: {
        const current_config: ?Config = read_config_leaky(io, alloc) catch null;

        const runner_user = if (maybe_user) |u|
            u
        else if (current_config) |c|
            c.runner_user
        else
            null;

        const config = Config{
            .port = if (current_config) |c| c.port else 9338,
            .max_workers = if (current_config) |c| c.max_workers else 8,
            .runner_user = runner_user,
        };

        try cwd.createDirPath(io, "/etc/weft");

        var config_file = try cwd.createFileAtomic(io, "/etc/weft/config.zon", .{
            .permissions = read_only_user_permissions,
            .replace = true,
        });

        var write_buffer: [4 << 10]u8 = undefined;
        var config_writer = config_file.file.writer(io, &write_buffer);

        try std.zon.stringify.serialize(config, .{}, &config_writer.interface);
        try config_writer.interface.flush();

        try config_file.replace(io);
        break :write_config;
    }

    setup_service: {
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
        const child_term = try child_en.wait(io);
        if (child_term != .exited or child_term.exited != 0)
            return error.SystemctlEnableFailed;

        var child_restart = try std.process.spawn(io, .{
            .argv = &.{ "systemctl", "restart", "weftd.service" },
        });
        const childr_term = try child_restart.wait(io);
        if (childr_term != .exited or childr_term.exited != 0)
            return error.SystemctlRestartFailed;

        break :setup_service;
    }
    setup_sysusers: {
        var sysusers_file = try cwd.createFile(io, sysusers_config_path, .{});
        defer sysusers_file.close(io);
        try sysusers_file.writeStreamingAll(io, sysusers_config);

        var child_en = try std.process.spawn(io, .{
            .argv = &.{ "systemd-sysusers", sysusers_config_path },
        });
        const t = try child_en.wait(io);
        if (t != .exited or t.exited != 0)
            return error.SystemdFailed;

        break :setup_sysusers;
    }
}

pub fn read_config_leaky(io: std.Io, gpa: std.mem.Allocator) !Config {
    const cwd = std.Io.Dir.cwd();

    var file = cwd.openFile(io, "/etc/weft/config.zon", .{}) catch |err| {
        if (err == error.AccessDenied)
            log(.config).err("cannot read /etc/weft/config.zon: permission denied (must be run as root)", .{})
        else if (err == error.FileNotFound)
            log(.config).err("daemon configuration missing, run 'weft daemon install' first: {any}", .{err});
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);

    if ((stat.permissions.toMode() & 0o777) != read_only_user_permissions.toMode()) {
        log(.config).err("/etc/weft/config.zon has insecure permissions, must be 0600", .{});
        return error.InsecurePermissions;
    }
    var buff: [4 << 10]u8 = undefined;
    var reader = file.reader(io, &buff);
    const content: [:0]const u8 = try reader.interface.allocRemainingAlignedSentinel(
        gpa,
        .unlimited,
        .of(u8),
        0,
    );

    var diag: std.zon.parse.Diagnostics = .{ .errors = &.{undefined} };
    return try std.zon.parse.fromSlice(Config, .{
        .arena = gpa,
        .gpa = gpa,
        .source = content,
        .diagnostics = &diag,
    });
}

pub const keys_file_path = "/etc/weft/keys";

pub fn get_keys(gpa: std.mem.Allocator, io: std.Io) ![][32]u8 {
    const l = log(.load_keys);
    const file = std.Io.Dir.cwd().openFile(io, keys_file_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .lock = .shared,
        .mode = .read_only,
    }) catch |err| {
        if (err == error.FileNotFound)
            return &.{};
        return err;
    };
    defer file.close(io);
    var buf: [1 << 6]u8 = undefined;
    var reader = file.reader(io, &buf);

    const content = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(content);

    var list: std.ArrayListUnmanaged([32]u8) = .empty;
    defer list.deinit(gpa);

    var iter = std.mem.splitScalar(u8, content, '\n');
    var ln: usize = 0;
    while (iter.next()) |entry| : (ln += 1) {
        if (entry.len == 0)
            continue
        else if (entry.len != 64) {
            l.err("Invalid client key with length {d} at /etc/weft/keys:{d}", .{ entry.len, ln });
            continue;
        } else {
            var key: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&key, entry) catch |err| {
                l.err("Error decoding key at /etc/weft/keys:{d} {any}", .{ ln, err });
                continue;
            };
            try list.append(gpa, key);
        }
    }

    return try list.toOwnedSlice(gpa);
}

pub fn add_key(io: std.Io, key: [32]u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, "/etc/weft") catch {};

    var file = try cwd.createFile(io, keys_file_path, .{
        .truncate = false,
        .permissions = read_only_user_permissions,
        .lock = .exclusive,
    });
    defer file.close(io);

    const offset = try file.length(io);
    const hex = std.fmt.bytesToHex(key, .upper);

    if (offset > 0) {
        var entry: [65]u8 = undefined;
        entry[0] = '\n';
        @memcpy(entry[1..], &hex);
        try file.writePositionalAll(io, &entry, offset);
    } else {
        try file.writePositionalAll(io, &hex, 0);
    }
}
