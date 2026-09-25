const std = @import("std");

const ClientInstall = @import("../client/ClientInstall.zig");
const read_only_user_permissions = ClientInstall.read_only_user_permissions;
const read_only_user_mode = ClientInstall.read_only_user_mode;
const Deployment = @import("../client/Deployment.zig");
const proto = @import("../domain/proto.zig");
const paths = @import("../domain/paths.zig");
const Term = @import("../domain/Term.zig");

const client_config_size_limit: std.Io.Limit = .limited(10 << 10);

pub const Config = struct {
    const Runner = struct {
        user: ?[]const u8 = null,
    };
    secret: []const u8,
    port: u16 = 9338,
    max_workers: u32 = 8,
    runner: Runner = .{},

    pub fn get_secret(self: @This()) ![32]u8 {
        var secret: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&secret, self.secret);
        return secret;
    }
};

temp_dir: std.Io.Dir,

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

pub fn init(io: std.Io) !@This() {
    const temp_dir = try std.Io.Dir.cwd().createDirPathOpen(
        io,
        "/var/lib/weft/tmp",
        .{ .open_options = .{ .iterate = true } },
    );
    return .{
        .temp_dir = temp_dir,
    };
}

pub fn open_temp(self: @This(), io: std.Io, sub: []const u8) !std.Io.Dir {
    const uuid = (try Deployment.Id.now(io)).to_string();

    var tmp_dir = std.Io.Dir.cwd().createDirPathOpen(
        io,
        paths.weft_tmp_dir,
        .{ .open_options = .{ .iterate = true } },
    ) catch return self.temp_dir.createDirPathOpen(io, sub, .{});
    defer tmp_dir.close(io);

    try tmp_dir.createDirPath(io, sub);
    var sub_dir = try tmp_dir.createDirPathOpen(io, sub, .{});
    defer sub_dir.close(io);

    return try sub_dir.createDirPathOpen(io, &uuid, .{});
}

pub fn install(io: std.Io, alloc: std.mem.Allocator, term: *Term, maybe_user: ?[]const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "/var/lib/weft/run");
    try cwd.createDirPath(io, "/var/lib/weft/artifacts");
    term.debug("created /var/lib/weft directory tree", .{});

    var child_stop = try std.process.spawn(io, .{
        .argv = &.{ "systemctl", "stop", "weftd.service" },
    });
    _ = try child_stop.wait(io);

    install_exe: {
        const exe_path = try std.process.executablePathAlloc(io, alloc);
        defer alloc.free(exe_path);

        if (!std.mem.eql(u8, exe_path, "/usr/local/bin/weft")) {
            const bin_dir = try cwd.openDir(io, "/usr/local/bin", .{});
            defer bin_dir.close(io);

            try cwd.copyFile(exe_path, bin_dir, "weft", io, .{});
        }
        break :install_exe;
    }
    term.debug("installed binary to /usr/local/bin/weft", .{});

    write_config: {
        const current_config: ?Config = read_config(io, alloc, null) catch null;
        defer if (current_config) |c| std.zon.parse.free(alloc, c);

        var secret: [32]u8 = undefined;
        var secret_hex_buf: [64]u8 = undefined;
        const secret_hex: []const u8 = if (current_config) |c|
            c.secret
        else blk: {
            try io.randomSecure(&secret);
            secret_hex_buf = std.fmt.bytesToHex(&secret, .lower);
            break :blk &secret_hex_buf;
        };

        const runner_user = if (maybe_user) |u|
            u
        else if (current_config) |c|
            c.runner.user
        else
            null;

        const config = Config{
            .secret = secret_hex,
            .port = if (current_config) |c| c.port else 9338,
            .max_workers = if (current_config) |c| c.max_workers else 8,
            .runner = .{
                .user = runner_user,
            },
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
        _ = try child_en.wait(io);

        var child_restart = try std.process.spawn(io, .{
            .argv = &.{ "systemctl", "restart", "weftd.service" },
        });
        _ = try child_restart.wait(io);

        break :setup_service;
    }
    setup_sysusers: {
        var sysusers_file = try cwd.createFile(io, sysusers_config_path, .{});
        defer sysusers_file.close(io);
        try sysusers_file.writeStreamingAll(io, sysusers_config);

        var child_en = try std.process.spawn(io, .{
            .argv = &.{ "systemd-sysusers", sysusers_config_path },
        });
        _ = try child_en.wait(io);

        break :setup_sysusers;
    }
}

pub fn read_config(io: std.Io, alloc: std.mem.Allocator, term: ?*Term) !Config {
    const cwd = std.Io.Dir.cwd();

    var file = cwd.openFile(io, "/etc/weft.zon", .{}) catch |err| {
        if (term) |t|
            if (err == error.AccessDenied)
                t.err("cannot read /etc/weft.zon: permission denied (must be run as root)", .{})
            else
                t.err("daemon configuration missing, run 'weft daemon install' first: {any}", .{err});
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);

    if ((stat.permissions.toMode() & 0o777) != read_only_user_mode) {
        if (term) |t|
            t.err("/etc/weft.zon has insecure permissions, must be 0600", .{});
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
    defer alloc.free(null_terminated);

    return try std.zon.parse.fromSliceAlloc(
        Config,
        alloc,
        null_terminated,
        null,
        .{},
    );
}

pub fn get_config(self: @This(), io: std.Io, alloc: std.mem.Allocator, term: ?*Term) !Config {
    _ = self;
    return read_config(io, alloc, term);
}
