const std = @import("std");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    unit: []const u8,
    opts: struct {
        cmd: []const []const u8,
        raw: []const []const u8 = &.{},
        unit: struct {
            description: ?[]const u8 = null,
            type: enum { simple, exec, oneshot, forking, notify, notify_reload, dbus, idle } = .simple,
        } = .{},
        run: struct {
            user: ?[]const u8 = null,
            group: ?[]const u8 = null,
            dynamic_user: bool = false,
            pipe: bool = false,
            pty: bool = false,
            collect: bool = false,
            remain_after_exit: bool = false,
            cwd: ?[]const u8 = null,
            env: []const []const u8 = &.{},
            wait: bool = false,
        } = .{},
        fs: struct {
            protect_home: enum { no, yes, tmpfs, read_only } = .no,
            protect_system: enum { no, yes, full, strict } = .no,
            read: []const []const u8 = &.{},
            write: [][]const u8 = &.{},
            inaccessible: []const []const u8 = &.{},
            private_tmp: bool = false,
            tmpfs: []const []const u8 = &.{},
            root_image: ?[]const u8 = null,
        } = .{},
        permissions: struct {
            no_new_privileges: bool = false,
            protect_kernel_tunables: bool = false,
            protect_kernel_modules: bool = false,
            protect_control_groups: bool = false,
            private_network: bool = false,
            capability_bounding_set: ?[]const u8 = null,
            private_devices: bool = false,
            restrict_address_families: ?[]const []const u8 = null,
        } = .{},
        resources: struct {
            memory_max: ?u64 = null,
            memory_high: ?u64 = null,
            cpu_quota: ?u16 = null,
            tasks_max: ?u32 = null,
            io_weight: ?u32 = null,
            timeout: ?u32 = null,
        } = .{},
    },
) !std.process.Child {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cmd: std.ArrayList([]const u8) = .empty;
    defer cmd.deinit(alloc);

    try cmd.append(alloc, "systemd-run");

    unit: {
        try cmd.append(
            alloc,
            try std.fmt.allocPrint(alloc, "--unit={s}", .{unit}),
        );

        if (opts.unit.description) |desc|
            try cmd.append(
                alloc,
                try std.fmt.allocPrint(alloc, "--description={s}", .{desc}),
            );

        try cmd.append(
            alloc,
            switch (opts.unit.type) {
                .notify_reload => "--service-type=notify-reload",
                .simple => "--service-type=simple",
                .exec => "--service-type=exec",
                .oneshot => "--service-type=oneshot",
                .forking => "--service-type=forking",
                .notify => "--service-type=notify",
                .dbus => "--service-type=dbus",
                .idle => "--service-type=idle",
            },
        );
        break :unit;
    }
    run: {
        if (opts.run.user) |user|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pUser={s}", .{user}));
        if (opts.run.group) |group|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pGroup={s}", .{group}));

        if (opts.run.wait)
            try cmd.append(alloc, "--wait");
        if (opts.run.pipe)
            try cmd.append(alloc, "--pipe");
        if (opts.run.dynamic_user)
            try cmd.append(alloc, "-pDynamicUser=yes");
        if (opts.run.pty)
            try cmd.append(alloc, "--pty");
        if (opts.run.collect)
            try cmd.append(alloc, "--collect");
        if (opts.run.remain_after_exit)
            try cmd.append(alloc, "--remain-after-exit");

        if (opts.run.cwd) |cwd|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "--working-directory={s}", .{cwd}));

        for (opts.run.env) |env| {
            try cmd.append(alloc, "-E");
            try cmd.append(alloc, env);
        }

        break :run;
    }
    fs: {
        switch (opts.fs.protect_home) {
            .no => {},
            .yes => try cmd.append(alloc, "-pProtectHome=yes"),
            .tmpfs => try cmd.append(alloc, "-pProtectHome=tmpfs"),
            .read_only => try cmd.append(alloc, "-pProtectHome=read-only"),
        }

        switch (opts.fs.protect_system) {
            .no => {},
            .yes => try cmd.append(alloc, "-pProtectSystem=yes"),
            .full => try cmd.append(alloc, "-pProtectSystem=full"),
            .strict => try cmd.append(alloc, "-pProtectSystem=strict"),
        }

        for (opts.fs.read) |read_path|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pReadOnlyPaths={s}", .{read_path}));

        for (opts.fs.write) |write_path|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pReadWritePaths={s}", .{write_path}));

        for (opts.fs.inaccessible) |inaccessible_path|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pInaccessiblePaths={s}", .{inaccessible_path}));

        if (opts.fs.private_tmp)
            try cmd.append(alloc, "-pPrivateTmp=yes");

        for (opts.fs.tmpfs) |spec|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pTemporaryFileSystem={s}", .{spec}));

        if (opts.fs.root_image) |img|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pRootImage={s}", .{img}));

        break :fs;
    }
    permissions: {
        if (opts.permissions.no_new_privileges)
            try cmd.append(alloc, "-pNoNewPrivileges=yes");
        if (opts.permissions.protect_kernel_tunables)
            try cmd.append(alloc, "-pProtectKernelTunables=yes");
        if (opts.permissions.protect_kernel_modules)
            try cmd.append(alloc, "-pProtectKernelModules=yes");
        if (opts.permissions.protect_control_groups)
            try cmd.append(alloc, "-pProtectControlGroups=yes");

        if (opts.permissions.capability_bounding_set) |cap|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pCapabilityBoundingSet={s}", .{cap}));

        if (opts.permissions.private_devices)
            try cmd.append(alloc, "-pPrivateDevices=yes");
        if (opts.permissions.private_network)
            try cmd.append(alloc, "-pPrivateNetwork=yes");

        if (opts.permissions.restrict_address_families) |addr|
            try cmd.append(
                alloc,
                try std.fmt.allocPrint(
                    alloc,
                    "-pRestrictAddressFamilies={s}",
                    .{try std.mem.join(alloc, " ", addr)},
                ),
            );

        break :permissions;
    }
    resources: {
        if (opts.resources.memory_max) |memax|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pMemoryMax={d}M", .{memax}));

        if (opts.resources.memory_high) |memhigh|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pMemoryHigh={d}M", .{memhigh}));

        if (opts.resources.cpu_quota) |quota|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pCPUQuota={d}%", .{quota}));

        if (opts.resources.tasks_max) |max_tasks|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pTasksMax={d}", .{max_tasks}));

        if (opts.resources.io_weight) |io_weight|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pIOWeight={d}", .{io_weight}));

        if (opts.resources.timeout) |timeout|
            try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pTimeoutStartSec={d}", .{timeout}));

        break :resources;
    }

    for (opts.raw) |arg|
        try cmd.append(alloc, arg);

    command: {
        try cmd.append(alloc, "--");
        for (opts.cmd) |arg|
            try cmd.append(alloc, arg);
        break :command;
    }

    const argv = try cmd.toOwnedSlice(alloc);

    const all = try std.mem.join(alloc, " ", argv);
    defer alloc.free(all);
    std.debug.print("Spawnig:  {s}", .{all});

    return try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

pub const UnitStatus = struct {};

pub fn show(alloc: std.mem.Allocator, io: std.Io, unit: []const u8) !UnitStatus {
    _ = alloc;
    const child = try std.process.spawn(
        io,
        .{
            .argv = &.{ "systemctl", "show", unit },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
        },
    );
    _ = try child.wait(io);

    if (child.stdout) |stdout| {
        var buffer: [4 << 10]u8 = undefined;
        var reader = stdout.reader(io, &buffer);
        reader.interface.discard(.unlimited);
        return .{};
    } else return error.NoStdout;
}

pub fn logs(io: std.Io, unit: []const u8) !std.process.Child {
    const child = try std.process.spawn(io, .{
        .argv = &.{ "journalctl", "-u", unit, "-f", "-o", "cat", "--no-pager" },
        .stdin = .ignore,
        .stderr = .inherit,
        .stdout = .pipe,
    });
    return child;
}

pub fn freeze(io: std.Io, unit: []const u8) !void {
    const child = try std.process.spawn(
        io,
        .{
            .argv = &.{ "systemctl", "freeze", unit },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        },
    );
    _ = try child.wait(io);
}

pub fn kill(io: std.Io, unit: []const u8) !void {
    const child = try std.process.spawn(
        io,
        .{
            .argv = &.{ "systemctl", "kill", unit },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        },
    );
    _ = try child.wait(io);
}
