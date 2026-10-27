const std = @import("std");
const log = std.log.scoped;

const ClientInstall = @import("../client/ClientInstall.zig");
const Deployment = @import("../client/Deployment.zig");
const paths = @import("../domain/paths.zig");
const read_only_user_permissions = paths.read_only_user_permissions;
const proto = @import("../domain/proto.zig");

pub const Config = struct {
    runner_user: ?[]const u8 = null,
    port: u16 = 9338,
    max_workers: u32 = 8,
    max_nix_workers: u32 = 5,
    compress: bool = false,
};

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

pub const InitSystem = enum {
    systemd,
    runit,

    pub fn detect(io: std.Io) !?@This() {
        const cwd = std.Io.Dir.cwd();
        if (cwd.access(io, "/run/systemd/system", .{})) |_|
            return .systemd
        else |e| if (e != error.FileNotFound)
            return .systemd;
        if (cwd.access(io, "/run/runit/runsvdir", .{})) |_|
            return .runit
        else |e| if (e != error.FileNotFound)
            return .runit;
        return null;
    }

    pub fn stop(self: @This(), io: std.Io, svc: []const u8) !void {
        const cmd: []const []const u8 = switch (self) {
            .systemd => &.{ "systemctl", "stop", svc },
            .runit => &.{ "sv", "stop", svc },
        };
        _ = try _do(io, cmd);
    }
    pub fn start(self: @This(), io: std.Io, svc: []const u8) !void {
        const cmd: []const []const u8 = switch (self) {
            .systemd => &.{ "systemctl", "start", svc },
            .runit => &.{ "sv", "start", svc },
        };
        _ = try _do(io, cmd);
    }
    pub fn restart(self: @This(), io: std.Io, svc: []const u8) !void {
        const cmd: []const []const u8 = switch (self) {
            .systemd => &.{ "systemctl", "restart", svc },
            .runit => &.{ "sv", "restart", svc },
        };
        _ = try _do(io, cmd);
    }
    pub fn _do(io: std.Io, cmd: []const []const u8) !std.process.Child.Term {
        const l = log(.init_system_manager);
        var child = try std.process.spawn(io, .{
            .argv = cmd,
        });
        const term = try child.wait(io);
        if (!term.success() or term.exited != 0) {
            l.err("Error spawning task: {any}", .{term});
            return error.CallFailed;
        }
        return term;
    }
    pub fn setup_weft_svc(self: @This(), io: std.Io) !void {
        const cwd: std.Io.Dir = .cwd();
        switch (self) {
            .systemd => {
                try cwd.writeFile(io, .{
                    .data =
                    \\[Unit]
                    \\Description=Weft daemon
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
                    ,
                    .sub_path = "/etc/systemd/system/weft.service",
                });

                _ = try _do(io, &.{ "systemctl", "daemon-reload" });
                _ = try _do(io, &.{ "systemctl", "enable", "--now", "weft.service" });
                _ = try _do(io, &.{ "systemctl", "restart", "weft.service" });
            },
            .runit => {
                try cwd.createDirPath(io, "/etc/sv/weft");
                try cwd.writeFile(io, .{ .data =
                    \\ #!/usr/bin/sh
                    \\
                    \\ exec 2>&1
                    \\
                    \\ /usr/local/bin/weft daemon run
                , .sub_path = "/etc/sv/weft/run", .flags = .{
                    .permissions = .executable_file,
                } });
                cwd.symLink(
                    io,
                    "/etc/sv/weft",
                    "/var/service/weft",
                    .{ .is_directory = true },
                ) catch |err|
                    if (err != error.FileExists)
                        return err;
                _ = try _do(io, &.{ "sv", "restart", "weft" });
            },
        }
    }
    pub fn setup_runner(self: @This(), io: std.Io) !void {
        const l = log(.init_system_manager);
        const cwd: std.Io.Dir = .cwd();
        switch (self) {
            .systemd => {
                try cwd.writeFile(io, .{
                    .data = "u weft - \"Weft pipeline runner\" /var/lib/weft /usr/bin/nologin",
                    .sub_path = "/usr/lib/sysusers.d/weft.conf",
                });
                _ = try _do(io, &.{ "systemd-sysusers", "/usr/lib/sysusers.d/weft.conf" });
            },
            .runit => {
                var child = try std.process.spawn(io, .{
                    .argv = &.{
                        "useradd",
                        "--system",
                        "--shell",
                        "/usr/bin/nologin",
                        "--home-dir",
                        "/var/lib/weft",
                        "--comment",
                        "Weft pipeline runner",
                        "weft",
                    },
                });
                const term = try child.wait(io);
                if (!term.success() or term.exited != 0 or term.exited != 9) {
                    l.err("Error adding 'weft' user task: {any}", .{term});
                    return error.CallFailed;
                }
            },
        }
    }
};

pub fn install(gpa: std.mem.Allocator, io: std.Io, maybe_user: ?[]const u8) !void {
    const l = log(.daemon_install);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cwd = std.Io.Dir.cwd();

    const pid1: InitSystem = try InitSystem.detect(io) orelse {
        l.err("No supported init system found", .{});
        return error.NoInitSystemFound;
    };

    pid1.stop(io, "weft") catch |err| {
        l.info("Could not stop existing service: {any}", .{err});
    };

    install_exe: {
        const exe_path = try std.process.executablePathAlloc(io, alloc);

        if (!std.mem.eql(u8, exe_path, "/usr/local/bin/weft")) {
            const bin_dir = try cwd.openDir(io, "/usr/local/bin", .{});
            defer bin_dir.close(io);

            try cwd.copyFile(exe_path, bin_dir, "weft", io, .{});
        }
        break :install_exe;
    }

    l.debug("installed binary to /usr/local/bin/weft", .{});

    write_config: {
        const current_config: ?Config = read_config_leaky(alloc, io) catch null;

        const runner_user = if (maybe_user) |u|
            u
        else if (current_config) |c|
            c.runner_user
        else
            null;

        const config = Config{
            .port = if (current_config) |c|
                c.port
            else
                9338,
            .max_workers = if (current_config) |c|
                c.max_workers
            else
                8,
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
    paths.ensure_dirs(io);

    try pid1.setup_weft_svc(io);
    try pid1.setup_runner(io);
    try setup_bin(gpa, io);
}

const allowed_tools =
    "sh,bash,dash,cat,cp,mv,rm,mkdir,rmdir,touch,chmod,chown,chgrp,ln,ls,readlink,realpath," ++
    "basename,dirname,mktemp,stat,sync,pwd,df,du,head,tail,sort,uniq,wc,cut,tr,tee,paste,split," ++
    "fold,fmt,nl,comm,csplit,join,expand,unexpand,od,tac,rev,md5sum,sha1sum,sha224sum," ++
    "sha256sum,sha384sum,sha512sum,b2sum,base64,base32,cksum,echo,printf,test,[,true,false," ++
    "sleep,env,printenv,date,uname,which,id,whoami,groups,timeout,kill,yes,nohup,expr,seq,grep," ++
    "egrep,fgrep,sed,awk,gawk,find,xargs,tar,gzip,gunzip,zcat,bzip2,bunzip2,bzcat,xz,unxz," ++
    "xzcat,zstd,unzstd,zip,unzip,diff,diff3,patch,cmp,file";

pub fn setup_bin(gpa: std.mem.Allocator, io: std.Io) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    paths.ensure_dirs(io);
    var bin_dir: std.Io.Dir = try std.Io.Dir.cwd().openDir(io, paths.weft_bin_dir, .{});
    defer bin_dir.close(io);

    var tools = std.mem.splitScalar(u8, allowed_tools, ',');
    while (tools.next()) |tool| {
        const target = try alloc.print("/bin/{s}", .{tool});
        bin_dir.deleteFile(io, tool) catch {};
        bin_dir.symLink(
            io,
            target,
            tool,
            .{},
        ) catch {};
    }
}

pub fn read_config_leaky(ara: std.mem.Allocator, io: std.Io) !Config {
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
        ara,
        .unlimited,
        .of(u8),
        0,
    );

    var diag: std.zon.parse.Diagnostics = .{ .errors = &.{undefined} };
    return try std.zon.parse.fromSlice(Config, .{
        .arena = ara,
        .gpa = ara,
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

    var list: std.ArrayList([32]u8) = .empty;
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
