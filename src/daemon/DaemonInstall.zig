const std = @import("std");
const log = std.log.scoped;

const ClientInstall = @import("../client/ClientInstall.zig");
const read_only_user_permissions = ClientInstall.read_only_user_permissions;
const read_only_user_mode = ClientInstall.read_only_user_mode;
const Deployment = @import("../client/Deployment.zig");
const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");

pub const Config = struct {
    runner_user: ?[]const u8 = null,
    secret: []const u8,
    port: u16 = 9338,
    max_workers: u32 = 8,

    pub fn get_secret(self: @This()) ![32]u8 {
        var secret: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&secret, self.secret);
        return secret;
    }
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

        var secret_hex = secret_hex: {
            var stack_secret: [64]u8 = undefined;
            if (current_config) |c| {
                @memcpy(&stack_secret, c.secret);
                break :secret_hex stack_secret;
            } else {
                try io.randomSecure(stack_secret[0..32]);
                break :secret_hex std.fmt.bytesToHex(stack_secret[0..32], .lower);
            }
        };

        const runner_user = if (maybe_user) |u|
            u
        else if (current_config) |c|
            c.runner_user
        else
            null;

        const config = Config{
            .secret = &secret_hex,
            .port = if (current_config) |c| c.port else 9338,
            .max_workers = if (current_config) |c| c.max_workers else 8,
            .runner_user = runner_user,
        };

        var config_file = try cwd.createFileAtomic(io, "/etc/weft.zon", .{
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

    var file = cwd.openFile(io, "/etc/weft.zon", .{}) catch |err| {
        if (err == error.AccessDenied)
            log(.config).err("cannot read /etc/weft.zon: permission denied (must be run as root)", .{})
        else if (err == error.FileNotFound)
            log(.config).err("daemon configuration missing, run 'weft daemon install' first: {any}", .{err});
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);

    if ((stat.permissions.toMode() & 0o777) != read_only_user_mode) {
        log(.config).err("/etc/weft.zon has insecure permissions, must be 0600", .{});
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
