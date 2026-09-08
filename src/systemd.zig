pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: struct {
        cmd: [][]const u8,
        raw: []const u8 = &.{},
        unit: struct {
            name: [][]const u8,
            description: []const u8,
        },
        run: struct {
            pipe: bool = true,
            pty: bool = false,
            collect: bool = true,
            remain_after_exit: bool = true,
            cwd: ?[]const u8 = null,
            env: [][]const u8 = &.{},
            wait: bool,
        } = &.{},
        fs: struct {
            protect_home: enum { no, yes, tmpfs } = .yes,
            protect_system: ?enum { strict } = null,
            read: [][]const u8 = &.{},
            write: [][]const u8 = &.{},
            inaccessible: [][]const u8 = &.{},
            private_tmp: bool = true,
            tmpfs: [][]const u8 = &.{},
            root_image: ?[]const u8 = null,
        } = &.{},
        permissions: struct {
            priviledges: bool = true,
            kernel_tunables: bool = false,
            kernel_modules: bool = false,
            control_groups: bool = false,
            network: bool = true,
            capability_bounding_set: ?[]const u8 = &.{}, // drop root
            devices: bool = true,
            address_families: ?[][]const u8 = &.{ "AF_UNIX", "AF_INET", "AF_INET6" },
        } = &.{},
        resources: struct {
            memory_max: ?u64 = null,
            memory_high: ?u64 = null,
            cpu_quota: ?u16 = null,
            tasks_max: ?u32 = null,
            io_weight: ?u32 = null,
            timeout: ?u32 = null,
        } = &.{},
        user: ?[]const u8 = null,
        group: ?[]const u8 = null,
    },
) !std.process.Child {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cmd: std.ArrayList([]const u8) = .empty;
    defer cmd.deinit(alloc);

    try cmd.append(alloc, "systemd-run");
    try cmd.append(alloc, "--service-type=exec");

    unit: {
        try cmd.append(
            alloc,
            try std.fmt.allocPrint(
                alloc,
                "--unit={s}",
                .{
                    std.mem.join(alloc, "-", opts.unit.name),
                },
            ),
        );
        try cmd.append(
            alloc,
            try std.fmt.allocPrint(
                alloc,
                "--description={s}",
                .{
                    opts.unit.description,
                },
            ),
        );
        break :unit;
    }
    run: {
        if (opts.run.wait)
            try cmd.append(alloc, "--wait");
        if (opts.run.pipe)
            try cmd.append(alloc, "--pipe");

        if (opts.run.pty)
            try cmd.append(alloc, "--pty");
        if (opts.run.collect)
            try cmd.append(alloc, "--collect");
        if (opts.run.remain_after_exit)
            try cmd.append(alloc, "--remain-after-exit");

        if (opts.run.cwd) |cwd|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "--working-directory={s}", cwd));

        for (opts.run.env) |env| {
            try cmd.append(alloc, "-E");
            try cmd.append(alloc, env);
        }

        break :run;
    }
    fs: {
        switch (opts.fs.protect_home) {
            .yes => try cmd.append(alloc, "-pProtectHome=yes"),
            .no => try cmd.append(alloc, "-pProtectHome=no"),
            .tmpfs => try cmd.append(alloc, "-pProtectHome=tmpfs"),
        }

        if (opts.fs.protect_system) |val|
            switch (val) {
                .strict => try cmd.append(alloc, "-pProtectSystem=strict"),
            };

        for (opts.fs.read) |read_path|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pReadOnlyPaths={s}", .{read_path}));

        for (opts.fs.write) |write_path|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pReadWritePaths={s}", .{write_path}));

        for (opts.fs.inaccessible) |inaccessible_path|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pInaccessiblePaths={s}", .{inaccessible_path}));

        if (opts.fs.private_tmp)
            try cmd.append(alloc, "-pPrivateTmp=yes");

        for (opts.fs.tmpfs) |spec|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pTemporaryFileSystem={s}", spec));

        if (opts.fs.root_image) |img|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pRootImage={s}", img));

        break :fs;
    }
    permissions: {
        if (!opts.permissions.priviledges)
            try cmd.append(alloc, "-pNoNewPrivileges=yes");
        if (!opts.permissions.kernel_tunables)
            try cmd.append(alloc, "-pProtectKernelTunables=yes");
        if (!opts.permissions.kernel_modules)
            try cmd.append(alloc, "-pProtectKernelModules=yes");
        if (!opts.permissions.control_groups)
            try cmd.append(alloc, "-pProtectControlGroups=yes");
        if (opts.permissions.capability_bounding_set) |cap|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pCapabilityBoundingSet={s}", .{cap}));
        if (!opts.permissions.devices)
            try cmd.append(alloc, "-pPrivateDevices=yes");
        if (!opts.permissions.network)
            try cmd.append(alloc, "-pPrivateNetwork=yes");
        if (opts.permissions.address_families) |addr|
            try cmd.append(
                alloc,
                std.fmt.allocPrint(
                    alloc,
                    "-pRestrictAddressFamilies={s}",
                    .{
                        std.mem.join(alloc, " ", addr),
                    },
                ),
            );

        break :permissions;
    }
    resources: {
        if (opts.resources.memory_max) |memax|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pMemoryMax={any}M", .{memax}));

        if (opts.resources.memory_high) |memhigh|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pMemoryHigh={any}M", .{memhigh}));

        if (opts.resources.cpu_quota) |quota|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pCpuQuota={any}%", .{quota}));

        if (opts.resources.tasks_max) |max_tasks|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pTasksMax={any}", .{max_tasks}));

        if (opts.resources.io_weight) |io_weight|
            try cmd.append(alloc, std.fmt.allocPrint(alloc, "-pIoWeight={any}", .{io_weight}));

        if (opts.resources.timeout) |timeout|
            try cmd.append(alloc, "-pTimeoutStartSec={any}", .{timeout});

        break :resources;
    }

    if (opts.user) |u|
        try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pUser={s}", .{u}));
    if (opts.group) |g|
        try cmd.append(alloc, try std.fmt.allocPrint(alloc, "-pGroup={s}", .{g}));

    for (opts.raw) |arg|
        try cmd.append(alloc, arg);

    command: {
        try cmd.append(alloc, "--");
        for (opts.cmd) |arg|
            try cmd.append(alloc, arg);
        break :command;
    }

    const argv = try cmd.toOwnedSlice(alloc);

    return try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
}

const std = @import("std");
