const std = @import("std");
const log = std.log.scoped;

const ClientInstall = @import("../client/ClientInstall.zig");
const Deployment = @import("../client/Deployment.zig");
const domain = @import("../domain/domain.zig");
const read_only_user_permissions = domain.read_only_user_permissions;
const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");

pub const Isolate = packed struct(u8) {
    cgroups: bool,
    mount: bool,
    pid: bool,
    net: bool,
    _pad: u4 = 0,

    pub const templates = [_]struct { []const u8, @This() }{
        .{ "kvm", .{ .cgroups = true, .mount = true, .pid = true, .net = true } },
        .{ "lxc", .{ .cgroups = false, .mount = true, .pid = true, .net = true } },
        .{ "vz", .{ .cgroups = false, .mount = false, .pid = false, .net = false } },
        .{ "colab", .{ .cgroups = false, .mount = false, .pid = false, .net = false } },
    };
    pub fn template(name: []const u8) ?@This() {
        return inline for (templates) |t| {
            if (std.mem.eql(u8, t.@"0", name))
                break t.@"1";
        } else null;
    }
    pub const default = template("kvm") orelse unreachable;
};

pub const Scale = struct {
    max_workers: u32,
    compress: bool,
    decompress: bool,

    pub const templates = [_]struct { []const u8, @This() }{
        .{ "tiny", .{ .max_workers = 1, .compress = false, .decompress = false } },
        .{ "small", .{ .max_workers = 4, .compress = false, .decompress = true } },
        .{ "large", .{ .max_workers = 16, .compress = true, .decompress = true } },
    };
    pub fn template(name: []const u8) ?@This() {
        return inline for (templates) |t| {
            if (std.mem.eql(u8, t.@"0", name))
                break t.@"1";
        } else null;
    }
    pub const default = template("small") orelse unreachable;
};

pub const Config = struct {
    port: u16 = 9338,
    isolate: Isolate = .default,
    scale: Scale = .default,

    pub fn from_template(spec: ?[]const u8) !@This() {
        var cfg: @This() = .{};
        const s = spec orelse return cfg;
        var it = std.mem.splitScalar(u8, s, '-');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            if (Isolate.template(part)) |iso|
                cfg.isolate = iso
            else if (Scale.template(part)) |sc|
                cfg.scale = sc
            else {
                log(.config).err(
                    "unknown template component '{s}'. Valid isolates: kvm, lxc, vz, colab. Valid scales: tiny, small, large",
                    .{part},
                );
                return error.TemplateNotFound;
            }
        }
        return cfg;
    }
};

pub fn init(_: std.Io) !@This() {
    return .{};
}

pub const InitSystem = enum {
    systemd,
    runit,
    openrc,
    none,

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

        if (cwd.access(io, "/run/openrc", .{})) |_|
            return .openrc
        else |e| if (e != error.FileNotFound)
            return .openrc;

        return .none;
    }

    pub fn stop(self: @This(), io: std.Io, svc: []const u8) !void {
        const cmd: []const []const u8 = switch (self) {
            .systemd => &.{ "systemctl", "stop", svc },
            .runit => &.{ "sv", "stop", svc },
            .openrc => &.{ "rc-service", svc, "stop" },
            .none => {
                var buf: [32]u8 = undefined;
                const pid_content = std.Io.Dir.cwd().readFile(
                    io,
                    paths.weft_pid,
                    &buf,
                ) catch |e|
                    return if (e != error.FileNotFound)
                        e
                    else {};
                const pid = std.fmt.parseInt(i32, std.mem.trim(u8, pid_content, " \n\r\t"), 10) catch return;
                _ = std.os.linux.kill(pid, .TERM);
                std.Io.Dir.cwd().deleteFile(io, paths.weft_pid) catch {};
                return;
            },
        };
        _ = try _do(io, cmd);
    }
    pub fn start(self: @This(), io: std.Io, svc: []const u8) !void {
        const cmd: []const []const u8 = switch (self) {
            .systemd => &.{ "systemctl", "start", svc },
            .runit => &.{ "sv", "start", svc },
            .openrc => &.{ "rc-service", svc, "start" },
            .none => {
                try domain.spawn_detach(io, .{
                    .argv = &.{ paths.weft_binary, "daemon", "run" },
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                });
                return;
            },
        };
        _ = try _do(io, cmd);
    }
    pub fn restart(self: @This(), io: std.Io, svc: []const u8) !void {
        const cmd: []const []const u8 = switch (self) {
            .systemd => &.{ "systemctl", "restart", svc },
            .runit => &.{ "sv", "restart", svc },
            .openrc => &.{ "rc-service", svc, "restart" },
            .none => {
                try self.stop(io, svc);
                try self.start(io, svc);
                return;
            },
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
        const l = log(.init_system);
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
                l.info("Creating sv folder", .{});
                try cwd.createDirPath(io, "/etc/sv/weft");
                try cwd.writeFile(io, .{ .data =
                    \\#!/usr/bin/sh
                    \\exec 2>&1
                    \\/usr/local/bin/weft daemon run
                , .sub_path = "/etc/sv/weft/run", .flags = .{
                    .permissions = .executable_file,
                } });
                const already_supervised = if (cwd.access(io, "/etc/sv/weft/supervise/ok", .{})) |_| true else |_| false;
                cwd.symLink(
                    io,
                    "/etc/sv/weft",
                    "/var/service/weft",
                    .{ .is_directory = true },
                ) catch |err| if (err != error.PathAlreadyExists)
                    return err;

                var waited: usize = 0;
                while (waited < 5) : (waited += 1) {
                    if (cwd.access(io, "/etc/sv/weft/supervise/ok", .{})) |_|
                        break
                    else |err| if (err == error.Canceled)
                        return err
                    else
                        try io.sleep(.fromSeconds(1), .awake);
                }
                const word = if (already_supervised)
                    "restart"
                else
                    "up";

                _ = try _do(io, &.{ "sv", word, "weft" });
            },
            .openrc => {
                try std.Io.Dir.cwd().writeFile(
                    io,
                    .{
                        .data = std.fmt.comptimePrint(
                            \\#!/sbin/openrc-run
                            \\name="weft"
                            \\command="{s}"
                            \\command_args="daemon run"
                            \\command_background="yes"
                            \\pidfile="{s}"
                        , .{ paths.weft_binary, paths.weft_pid }),

                        .sub_path = "/etc/init.d/weft",
                        .flags = .{
                            .permissions = .executable_file,
                        },
                    },
                );
                _ = try _do(io, &.{ "rc-update", "add", "weft", "default" });
                try self.restart(io, "weft");
            },
            .none => {
                try self.start(io, "weft");
            },
        }
    }
};

pub fn install(gpa: std.mem.Allocator, io: std.Io, template: ?[]const u8) !void {
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

        if (!std.mem.eql(u8, exe_path, paths.weft_binary))
            try cwd.copyFile(exe_path, cwd, paths.weft_binary, io, .{});

        break :install_exe;
    }

    l.debug("installed binary to {s}", .{paths.weft_binary});

    write_config: {
        var config = try Config.from_template(template);

        if (read_config_leaky(alloc, io)) |c| {
            config.port = c.port;
        } else |_| {}

        try cwd.createDirPath(io, paths.weft_config);

        var config_file = try cwd.createFileAtomic(io, paths.weft_config_file, .{
            .permissions = read_only_user_permissions,
            .replace = true,
        });

        var write_buffer: [4 << 10]u8 = undefined;
        var config_writer = config_file.file.writer(io, &write_buffer);

        try std.zon.stringify.serialize(config, .{}, &config_writer.interface);
        try config_writer.interface.flush();

        try config_file.replace(io);
        l.info("wrote daemon config to {s} (isolate: cgroups={}, mount={}, pid={}, net={}; scale: max_workers={d})", .{
            paths.weft_config_file,
            config.isolate.cgroups,
            config.isolate.mount,
            config.isolate.pid,
            config.isolate.net,
            config.scale.max_workers,
        });
        break :write_config;
    }
    try paths.ensure_dirs(io);
    l.info("configuring service with init system: {s}", .{@tagName(pid1)});
    try pid1.setup_weft_svc(io);
    try setup_bin(gpa, io);
    l.info("weft daemon successfully installed and started", .{});
}

const allowed_tools =
    "sh,bash,dash,cat,cp,mv,rm,mkdir,rmdir,touch,chmod,chown,chgrp,ln,ls,readlink,realpath," ++
    "basename,dirname,mktemp,stat,sync,pwd,df,du,head,tail,sort,uniq,wc,cut,tr,tee,paste,split," ++
    "fold,fmt,nl,comm,csplit,join,expand,unexpand,od,tac,rev,md5sum,sha1sum,sha224sum," ++
    "sha256sum,sha384sum,sha512sum,b2sum,base64,base32,cksum,echo,printf,test,[,true,false," ++
    "sleep,env,printenv,date,uname,which,id,whoami,groups,timeout,kill,yes,nohup,expr,seq,grep," ++
    "egrep,fgrep,sed,awk,gawk,find,xargs,tar,gzip,gunzip,zcat,bzip2,bunzip2,bzcat,xz,unxz," ++
    "xzcat,zstd,unzstd,zip,unzip,diff,diff3,patch,cmp,file,weft";

pub fn setup_bin(gpa: std.mem.Allocator, io: std.Io) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cwd = std.Io.Dir.cwd();

    var bin_dir: std.Io.Dir = try cwd.openDir(io, paths.weft_bin, .{});
    defer bin_dir.close(io);

    var tools = std.mem.splitScalar(u8, allowed_tools, ',');
    while (tools.next()) |tool| {
        if (bin_dir.access(io, tool, .{ .follow_symlinks = false })) |_| {
            continue;
        } else |_| {}

        const target = if (cwd.access(io, try alloc.print("/bin/{s}", .{tool}), .{})) |_|
            try alloc.print("/bin/{s}", .{tool})
        else |_| if (cwd.access(io, try alloc.print("/usr/local/bin/{s}", .{tool}), .{})) |_|
            try alloc.print("/usr/local/bin/{s}", .{tool})
        else |_|
            continue;

        cwd.hardLink(target, bin_dir, tool, io, .{ .follow_symlinks = true }) catch {
            cwd.copyFile(target, bin_dir, tool, io, .{}) catch continue;
            bin_dir.setFilePermissions(io, tool, .executable_file, .{}) catch {};
        };
    }
}

pub fn read_config_leaky(ara: std.mem.Allocator, io: std.Io) !Config {
    const cwd = std.Io.Dir.cwd();

    var file = cwd.openFile(io, paths.weft_config_file, .{}) catch |err| {
        if (err == error.AccessDenied)
            log(.config).err("cannot read {s}: permission denied (must be run as root)", .{paths.weft_config_file});
        return err;
    };
    defer file.close(io);

    const stat = try file.stat(io);

    if ((stat.permissions.toMode() & 0o777) != read_only_user_permissions.toMode()) {
        log(.config).err("{s} has insecure permissions, must be 0600", .{paths.weft_config_file});
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

pub fn get_keys(gpa: std.mem.Allocator, io: std.Io) ![][32]u8 {
    const l = log(.load_keys);
    const file = std.Io.Dir.cwd().openFile(io, paths.weft_config_keys, .{
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
            l.err("Invalid client key with length {d} at {s}:{d}", .{ entry.len, paths.weft_config_keys, ln });
            continue;
        } else {
            var key: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&key, entry) catch |err| {
                l.err("Error decoding key at {s}:{d} {any}", .{ paths.weft_config_keys, ln, err });
                continue;
            };
            try list.append(gpa, key);
        }
    }

    return try list.toOwnedSlice(gpa);
}

pub fn add_key(io: std.Io, key: [32]u8) !void {
    const cwd = std.Io.Dir.cwd();

    var file = try cwd.createFile(io, paths.weft_config_keys, .{
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
    } else try file.writePositionalAll(io, &hex, 0);
}
