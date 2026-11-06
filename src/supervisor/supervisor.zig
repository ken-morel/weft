const std = @import("std");

const Task = @import("../daemon/Task.zig");
const domain = @import("../domain/domain.zig");
const paths = @import("../domain/paths.zig");
const nix = @import("../nix/nix.zig");
const CGroup2 = @import("../util/CGroup2.zig");
const zoto = @import("../util/zoto.zig");
const mount = @import("mount.zig");

const default_max_pids = 256;
const max_freeze_depth = 32;

// I don't know much about this double fork
pub fn spawn_supervisor(io: std.Io, id: Task.Id) !void {
    const pid = std.os.linux.fork();
    if (std.os.linux.errno(pid) != .SUCCESS)
        return error.ForkFailed;

    if (pid == 0) {
        if (std.os.linux.errno(std.os.linux.setsid()) != .SUCCESS)
            std.os.linux.exit_group(1);

        const child_pid = std.os.linux.fork();
        if (std.os.linux.errno(child_pid) != .SUCCESS)
            std.os.linux.exit_group(1);
        if (child_pid != 0)
            std.os.linux.exit_group(0);

        _ = std.process.spawn(io, .{
            .argv = &.{
                "/proc/self/exe",
                "supervisor",
                "supervise",
                id.workspace,
                id.pipeline,
                &id.deployment.to_string(),
            },
        }) catch std.os.linux.exit_group(1);
        std.os.linux.exit_group(0);
    } else {
        var status: i32 = 0;
        _ = std.os.linux.waitpid(@intCast(pid), &status, 0);
    }
}

fn chown(parent: std.Io.Dir, sub_path: [:0]const u8, uid: u32, gid: u32) !void {
    const rc = std.os.linux.fchownat(parent.handle, sub_path.ptr, uid, gid, 0);
    if (std.os.linux.errno(rc) != .SUCCESS)
        return error.ChownFailed;
}

fn freeze_dir(io: std.Io, dir: std.Io.Dir, depth: u8) !void {
    if (depth > max_freeze_depth)
        return error.FreezeTooDeep;

    _ = std.os.linux.fchown(dir.handle, 0, 0);
    const dir_mode = (try dir.stat(io)).permissions.toMode();
    _ = std.os.linux.fchmod(dir.handle, 0o444 | (dir_mode & 0o111));

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const name_z = try std.posix.toPosixPath(entry.name);
        _ = std.os.linux.fchownat(dir.handle, &name_z, 0, 0, std.os.linux.AT.SYMLINK_NOFOLLOW);

        if (entry.kind == .directory) {
            var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub.close(io);
            try freeze_dir(io, sub, depth + 1);
        } else if (entry.kind == .file) {
            var f = try dir.openFile(io, entry.name, .{});
            defer f.close(io);
            const file_mode = (try f.stat(io)).permissions.toMode();
            _ = std.os.linux.fchmod(f.handle, 0o444 | (file_mode & 0o111));
        }
    }
}

fn first_active_sibling(gpa: std.mem.Allocator, io: std.Io, task: *const Task) !?Task {
    var siblings = try task.siblings(gpa, io, false);
    defer siblings.deinit(io);
    return while (try siblings.next(io)) |sibling| {
        if (try sibling.is_active(gpa, io))
            break sibling;
    } else null;
}

pub fn supervise(gpa: std.mem.Allocator, io: std.Io, task: Task) !void {
    _ = std.os.linux.syscall3(.setpriority, 0, 0, 10);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var barena: std.heap.ArenaAllocator = .init(gpa);
    defer barena.deinit();
    const balloc = barena.allocator();

    const cwd: std.Io.Dir = .cwd();

    const run_dir_path = try alloc.print(paths.task_run, task.id.wpd());
    const root_path = try alloc.print(paths.task_run_root, task.id.wpd());
    const task_dir_path = try alloc.print(paths.task, task.id.wpd());
    const scratch_path = try alloc.print(paths.scratch, task.id.wpd());
    const active_link = try alloc.printSentinel(paths.active_link, task.id.wpd(), 0);

    const l = l: {
        const log_path = try balloc.print(paths.task_log, task.id.wpd());
        const log_file = try cwd.createFile(io, log_path, .{ .truncate = false });
        defer log_file.close(io);
        _ = std.os.linux.dup2(log_file.handle, std.posix.STDOUT_FILENO);
        _ = std.os.linux.dup2(log_file.handle, std.posix.STDERR_FILENO);
        break :l std.log.scoped(.supervisor_supervise);
    };

    l.info("supervisor initialized", .{});

    ensure_dirs: {
        try cwd.createDirPath(io, root_path);
        try cwd.createDirPath(io, run_dir_path);
        try cwd.createDirPath(io, scratch_path);
        try cwd.symLinkAtomic(
            io,
            task_dir_path,
            active_link,
            .{ .is_directory = true },
        );
        break :ensure_dirs;
    }
    defer {
        cwd.deleteTree(io, run_dir_path) catch {};
        cwd.deleteTree(io, scratch_path) catch {};
        cwd.deleteFile(io, active_link) catch {};
    }

    const spec = try task.read_spec(gpa, alloc, io);
    const workspace = task.get_workspace();
    const uid = try workspace.uid(gpa, io);

    write_pid: {
        defer _ = barena.reset(.free_all);
        try domain.write_file_atomic(
            io,
            cwd,
            try balloc.print(paths.task_run_pid, task.id.wpd()),
            try balloc.print("{d}", .{std.os.linux.getpid()}),
            .{},
        );
        try task.write_status(gpa, io, .preparing);
        break :write_pid;
    }
    errdefer task.write_status(gpa, io, .failed) catch {};

    if (spec.pkgs.len > 0) {
        l.info("preparing {d} nix package(s)...", .{spec.pkgs.len});
        var client: std.http.Client = .{
            .io = io,
            .allocator = gpa,
        };
        defer client.deinit();

        for (spec.pkgs) |pkg|
            try nix.install_package(gpa, io, &client, pkg);

        l.info("all nix packages installed", .{});
    }

    prepare_files: {
        defer _ = barena.reset(.free_all);
        const home_path = try balloc.printSentinel(paths.workspace_home, task.id.w(), 0);
        try cwd.createDirPath(io, home_path);
        try chown(cwd, home_path, uid, uid);

        const cwd_path = try balloc.printSentinel(paths.scratch_cwd, task.id.wpd(), 0);
        try cwd.createDirPath(io, cwd_path);
        try chown(cwd, cwd_path, uid, uid);

        for (spec.outputs) |output| {
            const out_sub = try balloc.printSentinel(paths.scratch_output, task.id.wpd_(output), 0);
            try cwd.createDirPath(io, out_sub);
            try chown(cwd, out_sub, uid, uid);
        }

        for (spec.keep) |k| {
            const keep_host = try alloc.printSentinel(paths.keep, task.id.w_(k.@"0"), 0);
            try cwd.createDirPath(io, keep_host);
            try chown(cwd, keep_host, uid, uid);
        }
        break :prepare_files;
    }

    const skip = handle_siblings: {
        l.info("resolving sibling policies...", .{});

        const do_sibling = spec.sibling;
        if (do_sibling.poll == 0) {
            l.err("task has invalid sibling.poll of {d}", .{do_sibling.poll});
            return error.InvalidSiblingConfig;
        }

        var waited: u32 = 0;
        while (waited < do_sibling.wait) : (waited += do_sibling.poll) {
            const sibling = try first_active_sibling(gpa, io, &task) orelse break;
            const cgroup_name = try sibling.cgroup_name(gpa);
            defer gpa.free(cgroup_name);
            l.warn("waiting {d}s for active sibling {s}...", .{ do_sibling.wait - waited, cgroup_name });
            try std.Io.sleep(io, .fromSeconds(do_sibling.poll), .awake);
        }
        if (waited > 0)
            l.info("well, waited long enough", .{});

        switch (spec.sibling.then) {
            .ignore => {},
            .kill => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);
                while (try siblings.next(io)) |sibling|
                    if (try sibling.is_active(gpa, io)) {
                        const name = try sibling.cgroup_name(gpa);
                        defer gpa.free(name);
                        l.info("killing active sibling {s}", .{name});
                        try sibling.kill(gpa, io);
                    };
            },
            .fail => if (try first_active_sibling(gpa, io, &task)) |_| {
                l.err("sibling is still active after timeout; failing task", .{});
                return error.SiblingRunning;
            },
            .skip => if (try first_active_sibling(gpa, io, &task)) |_| {
                l.info("sibling is active; skipping task", .{});
                break :handle_siblings true;
            },
        }
        break :handle_siblings false;
    };

    if (skip) {
        l.info("task skipped", .{});
    } else {
        if (std.os.linux.errno(std.os.linux.unshare(std.os.linux.CLONE.NEWPID)) != .SUCCESS)
            return error.UnsharePidFailed;

        const cgroup = try task.cgroup(gpa);
        try cgroup.create(io);
        defer {
            cgroup.kill(gpa, io) catch {};
            cgroup.destroy(io) catch {};
            cgroup.deinit(gpa);
        }

        configure_cgroup: {
            const tune = &spec.tune;
            if ((tune.cpu.quota orelse tune.cpu.max) != null)
                try cgroup.cpu_max_set(gpa, io, tune.cpu.quota, tune.cpu.max);
            if (tune.io.io_weight) |w|
                try cgroup.io_weight_set(gpa, io, w);
            if (tune.mem.max) |r|
                try cgroup.memory_max_set(gpa, io, r);
            if (tune.mem.high) |r|
                try cgroup.memory_high_set(gpa, io, r);
            if (tune.mem.swap.max) |s|
                try cgroup.memory_swap_max_set(gpa, io, s);
            try cgroup.pids_max_set(gpa, io, tune.io.pids_max orelse default_max_pids);
            break :configure_cgroup;
        }

        var child = try std.process.spawn(io, .{
            .argv = &.{
                "/proc/self/exe",
                "supervisor",
                "spawn",
                task.id.workspace,
                task.id.pipeline,
                &task.id.deployment.to_string(),
            },
            .start_suspended = true,
        });
        const child_pid: std.posix.pid_t = child.id orelse unreachable;

        try cgroup.procs_add(gpa, io, child_pid);

        if (std.os.linux.errno(std.os.linux.kill(child_pid, .CONT)) != .SUCCESS)
            return error.KillContFailed;

        try task.write_status(gpa, io, .running);
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| l.info("task exited with code {d}", .{code}),
            .signal => |sig| l.err("task terminated by signal {s}", .{@tagName(sig)}),
            .stopped => |sig| l.err("task stopped by signal {s}", .{@tagName(sig)}),
            .unknown => |code| l.err("task terminated with unknown status {d}", .{code}),
        }
        if (!term.success())
            return error.TaskFailed;
    }
    try task.write_status(gpa, io, .harvesting);

    for (spec.outputs) |output| {
        defer _ = barena.reset(.free_all);
        const out_sub = try balloc.printSentinel(paths.scratch_output, task.id.wpd_(output), 0);

        {
            var staged = try cwd.openDir(io, out_sub, .{ .iterate = true });
            defer staged.close(io);
            try freeze_dir(io, staged, 0);
        }

        const artifact_path = try balloc.print(paths.artifact, task.id.w_d(output));

        cwd.deleteTree(
            io,
            artifact_path,
        ) catch |e| if (e != error.FileNotFound)
            return e;

        try cwd.rename(out_sub, cwd, artifact_path, io);
    }

    if (skip)
        try task.write_status(gpa, io, .skipped)
    else
        try task.write_status(gpa, io, .done);

    l.info("task completed and outputs harvested", .{});
}

const no_run_script = "#!/bin/env -S weft nop";

pub fn spawner(gpa: std.mem.Allocator, io: std.Io, task: Task) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const spec = try task.read_spec(gpa, alloc, io);
    const workspace = task.get_workspace();
    const uid = try workspace.uid(alloc, io);
    const username = try alloc.print("weft-{s}", .{workspace.name});

    const rootfs_path = try alloc.printSentinel(paths.task_run_root, task.id.wpd(), 0);

    const cwd: std.Io.Dir = .cwd();

    var flags: usize = std.os.linux.CLONE.NEWNS | std.os.linux.CLONE.NEWUTS | std.os.linux.CLONE.NEWIPC | std.os.linux.CLONE.NEWCGROUP;
    if (spec.tune.net.private)
        flags |= std.os.linux.CLONE.NEWNET;

    if (std.os.linux.errno(std.os.linux.unshare(flags)) != .SUCCESS)
        return error.UnshareFailed;

    try mount.isolate();
    try mount.mount_fs("tmpfs", rootfs_path, "tmpfs", "size=16m,mode=0755", true);

    {
        var rootfs_dir = try cwd.openDir(io, rootfs_path, .{});
        defer rootfs_dir.close(io);

        const user_home_rel = try alloc.printSentinel("home/{s}", .{username}, 0);
        for ([_][]const u8{
            "nix/store", "bin", "usr", "proc", "tmp", "dev/shm", "etc", "work", "in", "out", user_home_rel,
        }) |dir| {
            try rootfs_dir.createDirPath(io, dir);
        }

        _ = std.os.linux.symlinkat("/var/lib/weft/bin", rootfs_dir.handle, "usr/bin");

        const script = spec.script orelse no_run_script;
        try rootfs_dir.writeFile(io, .{
            .data = script,
            .sub_path = "entry",
            .flags = .{ .permissions = .executable_file },
        });

        const passwd = try alloc.print(
            \\root:x:0:0:root:/root:/bin/sh
            \\{s}:x:{d}:{d}:{s}:/home/{s}:/bin/sh
            \\nobody:x:65534:65534:nobody:/nonexistent:/bin/false
        ,
            .{ username, uid, uid, username, username },
        );
        try rootfs_dir.writeFile(
            io,
            .{ .data = passwd, .sub_path = "etc/passwd" },
        );

        const group = try alloc.print(
            \\root:x:0:
            \\{s}:x:{d}:
            \\nobody:x:65534:
        ,
            .{ username, uid },
        );
        try rootfs_dir.writeFile(
            io,
            .{ .data = group, .sub_path = "etc/group" },
        );

        if (std.os.linux.errno(std.os.linux.chdir(rootfs_path.ptr)) != .SUCCESS)
            return error.ChdirFailed;

        try mount.bind(
            paths.weft_nix_store,
            "nix/store",
            .{ .read_only = true, .allow_exec = true },
        );
        try mount.bind(
            paths.weft_bin,
            "bin",
            .{ .read_only = true, .allow_exec = true },
        );

        if (!spec.tune.net.private) {
            try rootfs_dir.writeFile(io, .{ .data = "", .sub_path = "etc/resolv.conf" });
            try mount.bind("/etc/resolv.conf", "etc/resolv.conf", .{ .read_only = true });
        }

        const host_home = try alloc.printSentinel(paths.workspace_home, task.id.w(), 0);
        try mount.bind(host_home, user_home_rel, .{ .read_only = false, .allow_exec = true });

        const host_cwd = try alloc.printSentinel(paths.scratch_cwd, task.id.wpd(), 0);
        try mount.bind(host_cwd, "work", .{ .read_only = false, .allow_exec = true });

        try mount.mount_fs("proc", "proc", "proc", null, false);
        try mount.mount_fs("tmpfs", "tmp", "tmpfs", "mode=1777", true);
        try mount.mount_fs("tmpfs", "dev/shm", "tmpfs", "mode=1777", false);

        inline for (.{ "null", "zero", "full", "random", "urandom" }) |dev| {
            try rootfs_dir.writeFile(
                io,
                .{ .data = "", .sub_path = "dev/" ++ dev },
            );
            try mount.bind(
                "/dev/" ++ dev,
                "dev/" ++ dev,
                .{ .read_only = false, .allow_dev = true },
            );
        }

        for (spec.inputs) |inp| {
            const target_in = try alloc.printSentinel(
                "in/{s}",
                .{inp},
                0,
            );
            try rootfs_dir.createDirPath(io, target_in);
            const host_in = try alloc.printSentinel(
                paths.artifact,
                task.id.w_d(inp),
                0,
            );
            try mount.bind(
                host_in,
                target_in,
                .{ .read_only = true, .allow_exec = true },
            );
        }

        for (spec.outputs) |out| {
            const target_out = try alloc.printSentinel(
                "out/{s}",
                .{out},
                0,
            );
            try rootfs_dir.createDirPath(io, target_out);
            const host_out = try alloc.printSentinel(
                paths.scratch_output,
                task.id.wpd_(out),
                0,
            );
            try mount.bind(host_out, target_out, .{ .read_only = false, .allow_exec = true });
        }

        for (spec.keep) |k| {
            const target_keep = try alloc.printSentinel(
                "work/{s}",
                .{k.@"1"},
                0,
            );
            try rootfs_dir.createDirPath(io, target_keep);
            const host_keep = try alloc.printSentinel(
                paths.keep,
                task.id.w_(k.@"0"),
                0,
            );
            try mount.bind(
                host_keep,
                target_keep,
                .{ .read_only = false, .allow_exec = true },
            );
        }
    }

    try mount.lock_read_only(".");
    try mount.pivot_root(".");
    if (std.os.linux.errno(std.os.linux.chdir("/work")) != .SUCCESS)
        return error.ChdirFailed;

    // Drop privileges to workspace UID/GID
    if (std.os.linux.errno(std.os.linux.syscall2(.setgroups, 0, 0)) != .SUCCESS)
        return error.SetGroupsFailed;
    if (std.os.linux.errno(std.os.linux.setresgid(uid, uid, uid)) != .SUCCESS)
        return error.SetGidFailed;
    if (std.os.linux.errno(std.os.linux.setresuid(uid, uid, uid)) != .SUCCESS)
        return error.SetUidFailed;
    if (std.os.linux.errno(std.os.linux.prctl(@backingInt(std.os.linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS)
        return error.NoNewPrivsFailed;

    var env_map = env_map: {
        var env_map: std.process.Environ.Map = .init(alloc);
        errdefer env_map.deinit();

        var path_writer: std.Io.Writer.Allocating = .init(alloc);
        defer path_writer.deinit();

        for (spec.pkgs) |pkg|
            try path_writer.writer.print("/nix/store/{s}/bin:", .{pkg});

        try path_writer.writer.writeAll("/bin");
        try path_writer.writer.flush();

        const home_val = try std.fmt.allocPrint(alloc, "/home/{s}", .{username});

        try env_map.put("PATH", try path_writer.toOwnedSlice());
        try env_map.put("HOME", home_val);
        try env_map.put("USER", username);
        try env_map.put("LOGNAME", username);
        try env_map.put("TMPDIR", "/tmp");
        try env_map.put("WEFT_VERSION", @import("build").version_str);
        try env_map.put("WEFT_MODE", spec.mode);
        try env_map.put("WEFT_WORKSPACE", spec.task_id.workspace);
        try env_map.put("WEFT_PIPELINE", spec.task_id.pipeline);
        try env_map.put("WEFT_DEPLOYMENT", try spec.task_id.deployment.to_string_alloc(alloc));

        for (spec.vars) |kv|
            try env_map.put(kv.@"0", kv.@"1");

        break :env_map env_map;
    };
    defer env_map.deinit();

    const child = try std.process.spawn(io, .{
        .argv = &.{"/entry"},
        .environ_map = &env_map,
    });
    const child_pid = child.id orelse unreachable;

    var status: u32 = 0;
    while (true) {
        const done = std.os.linux.waitpid(-1, @ptrCast(&status), 0); // takes i32 for status
        if (std.os.linux.errno(done) == .INTR)
            continue;
        if (done == child_pid) {
            const code: u8 = if (std.os.linux.W.IFEXITED(status))
                std.os.linux.W.EXITSTATUS(status)
            else
                128 + @as(u8, @truncate(@backingInt(std.os.linux.W.TERMSIG(status)))); // termsig returns u32
            std.os.linux.exit_group(code);
        }
    }
}
