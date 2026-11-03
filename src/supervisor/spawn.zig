

    const input_dirs = input_dirs: {
        const input_dirs = try alloc.alloc(
            []const u8,
            spec.inputs.len,
        );
        for (spec.inputs, input_dirs) |input, *input_dir| {
            const path = try paths.artifact(
                alloc,
                spec.task_id.workspace,
                &deployment,
                input,
            );
            std.Io.Dir.cwd().access(
                daemon.io,
                path,
                .{},
            ) catch |err|
                if (err == error.FileNotFound)
                    return error.MissingInputArtifact;

            input_dir.* = path;
        }
        break :input_dirs input_dirs;
    };

    const archive_dir_path = try task.archive(alloc);
    try std.Io.Dir.cwd().createDirPath(daemon.io, archive_dir_path);
    const log_path = try std.fs.path.join(alloc, &.{ archive_dir_path, "log.txt" });
    var log_file = try std.Io.Dir.cwd().createFile(daemon.io, log_path, .{ .truncate = false });
    defer log_file.close(io);

    // vehement leak, but it's just a few bytes
    try log_file.writeStreamingAll(io, try alloc.print("[weft::pkg] Installing packages\n", .{}));
    for (spec.pkgs) |basename| {
        try log_file.writeStreamingAll(io, try alloc.print("[weft::pkg] installing {s}...\n", .{basename}));
        daemon.store.fetch(io, basename) catch |err| {
            try log_file.writeStreamingAll(io, try alloc.print("[weft::pkg] failed to fetch {s}: {s}\n", .{ basename, @errorName(err) }));
            return err;
        };
        try log_file.writeStreamingAll(io, try alloc.print("[weft::pkg] installed {s}\n", .{basename}));
    }
    try log_file.writeStreamingAll(io, try alloc.print("[weft::pkg] done\n", .{}));
    try log_file.writeStreamingAll(io, try alloc.print("[weft::spawner] setting up environment\n", .{}));

    const run_dir_path = try task.run_dir_path(alloc);

    try std.Io.Dir.cwd().createDirPath(daemon.io, run_dir_path);

    const cwd_dir_path = try std.fs.path.join(alloc, &.{ run_dir_path, "cwd" });
    try std.Io.Dir.cwd().createDirPath(daemon.io, cwd_dir_path);

    const script_path = try std.fs.path.join(alloc, &.{ run_dir_path, "bin" });

    const nothing = if (spec.script) |script| script: {
        const script_file = try std.Io.Dir.cwd().createFile(daemon.io, script_path, .{
            .permissions = .executable_file,
        });
        defer script_file.close(io);
        try script_file.writeStreamingAll(io, script);
        break :script false;
    } else true;

    const runner_user = daemon.config.runner_user orelse "weft-runner";
    try log_file.writeStreamingAll(io, try alloc.print("[weft::spawner] running task as {s}\n", .{runner_user}));
    const is_default_runner = std.mem.eql(u8, runner_user, "weft-runner");

    const home_dir_path = if (is_default_runner)
        try paths.home(alloc, spec.task_id.workspace)
    else
        try alloc.print("/home/{s}", .{runner_user});

    if (is_default_runner)
        try std.Io.Dir.cwd().createDirPath(daemon.io, home_dir_path);

    const output_dir_path = try std.fs.path.join(alloc, &.{ run_dir_path, "out" });

    var state_dirs: std.ArrayList([]const u8) = try .initCapacity(alloc, spec.outputs.len + 2);
    try state_dirs.append(alloc, paths.state_dir(cwd_dir_path));
    if (is_default_runner)
        try state_dirs.append(alloc, paths.state_dir(home_dir_path));

    for (spec.outputs) |output| {
        const path = try std.fs.path.join(alloc, &.{
            output_dir_path,
            output,
        });
        try std.Io.Dir.cwd().createDirPath(daemon.io, path);
        try state_dirs.append(alloc, paths.state_dir(path));
    }
    const unit_name = try task.unit_name(alloc);
    var bind_paths: std.ArrayList([]const u8) = .empty;
    var bind_paths_read: std.ArrayList([]const u8) = .empty;

    if (spec.pkgs.len > 0) {
        try bind_paths_read.append(alloc, "/var/lib/weft/store:/nix/store");
        try bind_paths_read.append(alloc, "/var/lib/weft/store");
    }

    for (spec.keep) |keep| {
        const cache_path = try task.keep_path(alloc, keep.@"0");
        const mount_path = try std.fs.path.join(gpa, &.{ cwd_dir_path, keep.@"1" });
        defer gpa.free(mount_path);

        try std.Io.Dir.cwd().createDirPath(io, cache_path);
        try std.Io.Dir.cwd().createDirPath(io, mount_path);
        try state_dirs.append(alloc, paths.state_dir(cache_path));
        try bind_paths.append(
            alloc,
            try alloc.print("{s}:{s}", .{ cache_path, mount_path }),
        );
    }

    const env = bind_env: {
        var env: std.ArrayList([]const u8) = .empty;
        const input_dir_path = try paths.artifacts(
            alloc,
            spec.task_id.workspace,
            &deployment,
        );
        const env_vars = [_][2][]const u8{
            .{ "IN", input_dir_path },
            .{ "OUT", output_dir_path },

            .{ "HOME", home_dir_path },
            .{ "USER", runner_user },
            .{ "LOGNAME", runner_user },

            .{ "WEFT_MODE", spec.mode },
            .{ "WEFT_PIPELINE", spec.task_id.pipeline },
            .{ "WEFT_WORKSPACE", spec.task_id.workspace },
            .{ "WEFT_DEPLOYMENT", &deployment },
            .{ "WEFT_UNIT", unit_name },
        };
        for (&env_vars) |v|
            try env.append(alloc, try std.mem.join(alloc, "=", &v));

        const base_path = paths.weft_bin_dir[0 .. paths.weft_bin_dir.len - 1];
        if (spec.pkgs.len > 0) {
            var pkg_bin_paths: std.ArrayList([]const u8) = .empty;
            for (spec.pkgs) |basename| {
                const bin_dir = try alloc.print("/nix/store/{s}/bin", .{basename});
                try pkg_bin_paths.append(alloc, bin_dir);
            }
            const joined_bins = try std.mem.join(alloc, ":", pkg_bin_paths.items);
            try env.append(alloc, try alloc.print("PATH={s}:{s}", .{ joined_bins, base_path }));
        } else try env.append(alloc, try alloc.print("PATH={s}", .{base_path}));

        for (spec.vars) |pair|
            try env.append(alloc, try std.mem.join(alloc, "=", &.{ pair.@"0", pair.@"1" }));
        break :bind_env env;
    };

    const skip = handle_siblings: {
        try log_file.writeStreamingAll(io, try alloc.print("[weft::spawner] handling sibling instances(second_instance = {any})\n", .{spec.sibling}));
        const do_sibling = spec.sibling;
        if (do_sibling.poll <= 0)
            return error.InvalidSiblingConfig;

        var waited: u32 = 0;
        while (waited < do_sibling.wait) : (waited += do_sibling.poll) {
            var sibling_iter = try task.siblings(
                gpa,
                io,
                false,
            );
            defer sibling_iter.deinit(io);
            const sibling: Task = while (try sibling_iter.next(io)) |sibl| {
                if (try sibl.is_active(gpa, io))
                    break sibl;
            } else break;

            const unit = try sibling.unit_name(gpa);
            defer gpa.free(unit);
            try log_file.writeStreamingAll(io, try alloc.print("[weft::spawner] Waiting {d}s for sibling instance {s}\n", .{ do_sibling.wait - waited, unit }));
            try std.Io.sleep(io, .fromSeconds(do_sibling.poll), .awake);
        }

        switch (spec.sibling.then) {
            .ignore => {},
            .kill => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);
                while (try siblings.next(io)) |sibling|
                    if (try sibling.is_active(gpa, io)) {
                        try log_file.writeStreamingAll(io, try alloc.print("[weft::spawner] killing sibling task from {s}\n", .{&sibling.id.deployment.to_string()}));
                        try sibling.kill(gpa, io);
                    };
            },
            .fail => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);
                while (try siblings.next(io)) |sibling|
                    if (try sibling.is_active(gpa, io)) {
                        try log_file.writeStreamingAll(io, try alloc.print("[weft::spawner] found sibling {s}; failing\n", .{&sibling.id.deployment.to_string()}));
                        return error.AlreadyRunning;
                    };
            },
            .skip => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);

                break :handle_siblings while (try siblings.next(io)) |sibling| {
                    if (try sibling.is_active(gpa, io))
                        break true;
                } else false;
            },
        }

        break :handle_siblings false;
    };

    if (skip) {
        try log_file.writeStreamingAll(io, "[weft::spawner] Task is skipped \n");
        try clinternal.task_completed(gpa, io, task, -1);
        return .{ .status = .skipped };
    } else if (nothing) {
        try log_file.writeStreamingAll(io, "[weft::spawner] Task runs nothing \n");
        try clinternal.task_completed(gpa, io, task, -2);
        return .{ .status = .spawned };
    } else {
        try log_file.writeStreamingAll(io, "[weft::spawner] Spawning systemd-run for task ");
        try log_file.writeStreamingAll(io, unit_name);
        try log_file.writeStreamingAll(io, "\n");

        var child = try systemd.run(
            gpa,
            io,
            unit_name,
            .{
                .cmd = if (!skip) &.{script_path} else &.{ "/usr/bin/echo", "[weft.daemon.runner] Pipeline skipped" },
                .raw = &.{},
                .unit = .{
                    .type = .exec,
                    .description = try alloc.print("Weft runner", .{}),
                },
                .fs = .{
                    .inaccessible = &.{ "/etc/weft", paths.weft_runtime_dir },
                    .private_tmp = true,
                    .protect_system = .strict,
                    .read = input_dirs,
                    .write = &.{},
                    .root_image = null,
                    .tmpfs = &.{},
                    .bind_paths = bind_paths.items,
                    .bind_paths_read = bind_paths_read.items,
                },
                .permissions = .{
                    // just in case they had sudo password maybe?
                    .capability_bounding_set = &.{},
                    .protect_control_groups = true,
                    .private_devices = true,
                    .protect_kernel_modules = true,
                    .protect_kernel_tunables = true,
                    .private_network = spec.tune.disable_network,
                    .no_new_privileges = true,
                },
                .run = .{
                    .user = runner_user,
                    .group = null,
                    .wait = false,
                    .collect = true,
                    .cwd = cwd_dir_path,
                    .dynamic_user = false,
                    .state_directories = state_dirs.items,
                    .env = env.items,
                    .hooks = .{
                        .poststart = try alloc.print("+/bin/touch {s}/started", .{run_dir_path}),
                        .poststop = try alloc.print(
                            "+/usr/local/bin/weft daemon ipc completed {s} $EXIT_STATUS",
                            .{unit_name},
                        ),
                    },
                    .stderr = .{ .append = log_path },
                    .stdout = .{ .append = log_path },
                },
                .resources = .{
                    .memory_max = spec.tune.memory_max,
                    .memory_high = spec.tune.memory_high,
                    .cpu_quota = spec.tune.cpu_quota,
                    .tasks_max = spec.tune.tasks_max,
                    .io_weight = spec.tune.io_weight,
                    .timeout = spec.timeout, //TODO: Move to it's own field
                },
            },
        );