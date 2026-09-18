const std = @import("std");

const ClientInstall = @import("../client/ClientInstall.zig");
const read_only_user_permissions = ClientInstall.read_only_user_permissions;
const read_only_user_mode = ClientInstall.read_only_user_mode;
const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const UUIDv7 = @import("../util/UUIDv7.zig");

const client_config_size_limit: std.Io.Limit = .limited(10 << 10);

pub const Config = struct {
    secret: []const u8,
    port: u16 = 9338,
    max_workers: u32 = 8,

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
    \\ExecStart=/usr/local/bin/weft daemon
    \\Restart=always
    \\User=root
    \\WorkingDirectory=/var/lib/weft
    \\
    \\[Install]
    \\WantedBy=multi-user.target
;

//
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
    const uuid = (try UUIDv7.now(io)).to_string();

    self.temp_dir.createDirPath(io, sub) catch {};
    var sub_dir = try self.temp_dir.createDirPathOpen(io, sub, .{});
    defer sub_dir.close(io);

    try sub_dir.createDirPath(io, &uuid);
    return try sub_dir.openDir(io, &uuid, .{});
}

pub fn install(io: std.Io, alloc: std.mem.Allocator, term: *Term) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "/var/lib/weft/workspaces");
    try cwd.createDirPath(io, "/var/lib/weft/run");
    try cwd.createDirPath(io, "/var/lib/weft/artifacts");
    term.debug("created /var/lib/weft directory tree", .{});
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
        var secret: [32]u8 = undefined;
        try io.randomSecure(&secret);
        const secret_hex = std.fmt.bytesToHex(&secret, .lower);
        const config = Config{
            .secret = &secret_hex,
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

        term.println("secret: {s}", .{config.secret});

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

pub fn get_config(self: @This(), io: std.Io, alloc: std.mem.Allocator, term: ?*Term) !Config {
    _ = self;
    const cwd = std.Io.Dir.cwd();

    var file = cwd.openFile(io, "/etc/weft.zon", .{}) catch |err| {
        if (term) |t|
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

    return try std.zon.parse.fromSliceAlloc(
        Config,
        alloc,
        null_terminated,
        null,
        .{},
    );
}

pub fn get_artifact_path(
    self: @This(),
    alloc: std.mem.Allocator,
    art: proto.artifact.Id,
) ![]const u8 {
    _ = self;
    const uuid = art.deployment.to_string();
    return try std.fs.path.join(alloc, &.{
        "/var/lib/weft/artifacts/",
        art.workspace,
        art.service,
        art.env,
        &uuid,
        art.pipeline,
    });
}
pub fn open_artifact_dir(
    self: @This(),
    alloc: std.mem.Allocator,
    io: std.Io,
    art: proto.artifact.Id,
) !std.Io.Dir {
    const path = try self.get_artifact_path(alloc, art);
    defer alloc.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .open_options = .{
        .iterate = true,
    } });
}
