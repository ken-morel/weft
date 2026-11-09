const std = @import("std");

const DaemonInstall = @import("../daemon/DaemonInstall.zig");
const Task = @import("../daemon/Task.zig");
const domain = @import("../domain/domain.zig");
const spawn_detach = @import("../domain/domain.zig").spawn_detach;
const paths = @import("../domain/paths.zig");
const nix = @import("../nix/nix.zig");
const CGroup2 = @import("../util/CGroup2.zig");
const zoto = @import("../util/zoto.zig");
const mount = @import("mount.zig");

const default_max_pids = 256;
const max_freeze_depth = 32;

pub fn spawn_supervisor(gpa: std.mem.Allocator, io: std.Io, id: Task.Id, isolate: DaemonInstall.Isolate) !void {
    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);

    const isolate_arg = try gpa.print("{d}", .{@backingInt(isolate)});
    defer gpa.free(isolate_arg);

    var depl_buf = id.deployment.to_string();

    try spawn_detach(io, .{
        .argv = &.{
            exe_path,
            "supervisor",
            "supervise",
            id.workspace,
            id.pipeline,
            &depl_buf,
            isolate_arg,
        },
    });
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

pub fn supervise(gpa: std.mem.Allocator, io: std.Io, task: Task, isolate: DaemonInstall.Isolate) !void {
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
    const in_fifo_path = try alloc.printSentinel(paths.task_run_in, task.id.wpd(), 0);

    const l = l: {
        const log_path = try balloc.print(paths.task_log, task.id.wpd());
        const log_file = try cwd.createFile(io, log_path, .{
            .truncate = false,
            .permissions = domain.read_only_user_permissions,
        });

        const in_fd = std.os.linux.open(in_fifo_path.ptr, .{ .ACCMODE = .RDWR }, 0);
        if (std.os.linux.errno(in_fd) == .SUCCESS)
            _ = std.os.linux.dup2(@intCast(in_fd), std.posix.STDIN_FILENO);

        defer log_file.close(io);
        _ = std.os.linux.dup2(log_file.handle, std.posix.STDOUT_FILENO);
        _ = std.os.linux.dup2(log_file.handle, std.posix.STDERR_FILENO);
        break :l std.log.scoped(.supervisor_supervise);
    };

    const cgroup_name = try task.cgroup_name(gpa);
    defer gpa.free(cgroup_name);
    l.info("supervising task {s}", .{cgroup_name});

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
    l.debug("task directories and active link ready", .{}); //debug

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
            .{ .replace = true },
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

        for (spec.pkgs) |pkg| {
            l.debug("installing nix package {s}", .{pkg}); //debug
            try nix.install_package(gpa, io, &client, pkg);
        }

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
    l.debug("prepared home/cwd/outputs/keep directories", .{}); //debug

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
            const sibling_cgroup_name = try sibling.cgroup_name(gpa);
            defer gpa.free(sibling_cgroup_name);
            l.warn("waiting {d}s for active sibling {s}...", .{ do_sibling.wait - waited, sibling_cgroup_name });
            try std.Io.sleep(io, .fromSeconds(do_sibling.poll), .awake);
        }
        if (waited == 0)
            l.debug("no active siblings found", .{}); //debug
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
        if (isolate.pid) {
            if (std.os.linux.errno(std.os.linux.unshare(std.os.linux.CLONE.NEWPID)) != .SUCCESS)
                return error.UnsharePidFailed;
            l.debug("unshared pid namespace", .{}); //debug
        }

        const maybe_cgroup = if (isolate.cgroups) cg: {
            var cgroup = try task.cgroup(gpa);
            try cgroup.create(io);
            l.debug("Configuring cgroup: {s}", .{cgroup.path});
            l.debug("cgroup created", .{}); //debug

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
            l.debug("cgroup configured", .{}); //debug
            break :cg cgroup;
        } else null;
        var cgroup_mut = maybe_cgroup;
        defer if (cgroup_mut) |*cgroup| {
            cgroup.kill(gpa, io) catch {};
            cgroup.destroy(io) catch {};
            cgroup.deinit(gpa);
        };

        const isolate_arg = try alloc.print("{d}", .{@backingInt(isolate)});
        var depl_buf = task.id.deployment.to_string();
        const child = try std.process.spawn(io, .{
            .argv = &.{
                "/proc/self/exe",
                "supervisor",
                "spawn",
                task.id.workspace,
                task.id.pipeline,
                &depl_buf,
                isolate_arg,
            },
            .start_suspended = false,
        });
        const child_pid: std.posix.pid_t = child.id orelse unreachable;
        defer if (!isolate.cgroups) {
            _ = std.os.linux.kill(-child_pid, .KILL);
        };

        if (cgroup_mut) |*cgroup|
            try cgroup.procs_add(gpa, io, child_pid);

        l.debug("task running in sandbox (pid {d})", .{child_pid}); //debug

        try task.write_status(gpa, io, .running);
        var child_status: u32 = 0;
        const term: std.process.Child.Term = term: {
            while (true) {
                const res = std.os.linux.waitpid(child_pid, @ptrCast(&child_status), 0);
                if (std.os.linux.errno(res) == .INTR)
                    continue;
                if (std.os.linux.errno(res) != .SUCCESS) {
                    l.err("waitpid error: {s}", .{@tagName(std.os.linux.errno(res))});
                    return error.TaskFailed;
                }
                if (std.os.linux.W.IFEXITED(child_status))
                    break :term .{ .exited = std.os.linux.W.EXITSTATUS(child_status) }
                else if (std.os.linux.W.IFSIGNALED(child_status))
                    break :term .{ .signal = std.os.linux.W.TERMSIG(child_status) }
                else if (std.os.linux.W.IFSTOPPED(child_status))
                    break :term .{ .stopped = std.os.linux.W.STOPSIG(child_status) }
                else
                    break :term .{ .unknown = child_status };
            }
        };
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
    l.info("harvesting {d} output(s)", .{spec.outputs.len});

    for (spec.outputs) |output| {
        defer _ = barena.reset(.free_all);
        l.debug("harvesting output {s}", .{output}); //debug
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

        const artifact_parent = try balloc.print(paths.workspace ++ "artifact/{s}/", .{ task.id.workspace, output });
        try cwd.createDirPath(io, artifact_parent);

        try cwd.rename(out_sub, cwd, artifact_path, io);
    }

    if (skip)
        try task.write_status(gpa, io, .skipped)
    else
        try task.write_status(gpa, io, .done);

    l.info("task completed and outputs harvested", .{});
}

const no_run_script = "#!/bin/env -S weft nop";

pub fn spawner(gpa: std.mem.Allocator, io: std.Io, task: Task, isolate: DaemonInstall.Isolate) !void {
    const l = std.log.scoped(.supervisor_spawn);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var barena: std.heap.ArenaAllocator = .init(gpa);
    defer barena.deinit();
    const balloc = barena.allocator();

    const spec = try task.read_spec(gpa, alloc, io);
    l.info("spawning task {s}/{s}/{d}", .{ task.id.workspace, task.id.pipeline, task.id.deployment });
    const workspace = task.get_workspace();
    const uid = try workspace.uid(alloc, io);
    const username = try alloc.print("weft-{s}", .{workspace.name});

    const rootfs_path = try alloc.printSentinel(paths.task_run_root, task.id.wpd(), 0);
    const host_home = try alloc.printSentinel(paths.workspace_home, task.id.w(), 0);
    const host_cwd = try alloc.printSentinel(paths.scratch_cwd, task.id.wpd(), 0);
    const cwd: std.Io.Dir = .cwd();

    if (isolate.mount) {
        var flags: usize = std.os.linux.CLONE.NEWNS | std.os.linux.CLONE.NEWUTS | std.os.linux.CLONE.NEWIPC;
        if (isolate.cgroups)
            flags |= std.os.linux.CLONE.NEWCGROUP;
        if (isolate.net and spec.tune.net.private)
            flags |= std.os.linux.CLONE.NEWNET;

        if (std.os.linux.errno(std.os.linux.unshare(flags)) != .SUCCESS)
            return error.UnshareFailed;
        l.debug("unshared namespaces", .{}); //debug

        try mount.isolate();
        try mount.mount_fs("tmpfs", rootfs_path, "tmpfs", "size=16m,mode=0755", true);
        l.debug("rootfs tmpfs mounted", .{}); //debug

        {
            var rootfs_dir = try cwd.openDir(io, rootfs_path, .{});
            defer rootfs_dir.close(io);

            const user_home_rel = try gpa.printSentinel("home/{s}", .{username}, 0);
            defer gpa.free(user_home_rel);
            for ([_][]const u8{
                "nix/store", "bin",         "usr", "usr/lib", "proc",
                "tmp",       "dev/shm",     "etc", "work",    "in",
                "out",       user_home_rel,
            }) |dir|
                try rootfs_dir.createDirPath(io, dir);

            _ = std.os.linux.symlinkat("/bin", rootfs_dir.handle, "usr/bin");
            _ = std.os.linux.symlinkat("usr/lib", rootfs_dir.handle, "lib");
            _ = std.os.linux.symlinkat("usr/lib", rootfs_dir.handle, "lib64");
            _ = std.os.linux.symlinkat("lib", rootfs_dir.handle, "usr/lib64");

            const script = spec.script orelse no_run_script;
            try rootfs_dir.writeFile(io, .{
                .data = script,
                .sub_path = "entry",
                .flags = .{ .permissions = .executable_file },
            });

            {
                defer _ = barena.reset(.retain_capacity);
                const passwd = try balloc.print(
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

                const group = try balloc.print(
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
            }
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
            try mount.bind(
                "/usr/lib",
                "usr/lib",
                .{ .read_only = true, .allow_exec = true },
            );

            if (!spec.tune.net.private) {
                try rootfs_dir.writeFile(io, .{ .data = "", .sub_path = "etc/resolv.conf" });
                try mount.bind("/etc/resolv.conf", "etc/resolv.conf", .{ .read_only = true });

                inline for (.{
                    .{ "/etc/ssl", "etc/ssl" },
                    .{ "/etc/ca-certificates", "etc/ca-certificates" },
                    .{ "/etc/pki", "etc/pki" },
                }) |cert_pair| {
                    if (cwd.openDir(io, cert_pair.@"0", .{})) |dir| {
                        dir.close(io);
                        rootfs_dir.createDirPath(io, cert_pair.@"1") catch {};
                        mount.bind(cert_pair.@"0", cert_pair.@"1", .{ .read_only = true }) catch {};
                    } else |_| {}
                }
            }

            try mount.bind(host_home, user_home_rel, .{ .read_only = false, .allow_exec = true });
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
                defer _ = barena.reset(.retain_capacity);
                const target_in = try balloc.printSentinel(
                    "in/{s}",
                    .{inp},
                    0,
                );
                try rootfs_dir.createDirPath(io, target_in);
                const host_in = try balloc.printSentinel(
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
                defer _ = barena.reset(.retain_capacity);
                const target_out = try balloc.printSentinel(
                    "out/{s}",
                    .{out},
                    0,
                );
                try rootfs_dir.createDirPath(io, target_out);
                const host_out = try balloc.printSentinel(
                    paths.scratch_output,
                    task.id.wpd_(out),
                    0,
                );
                try mount.bind(host_out, target_out, .{ .read_only = false, .allow_exec = true });
            }

            for (spec.keep) |k| {
                defer _ = barena.reset(.retain_capacity);
                const target_keep = try balloc.printSentinel(
                    "work/{s}",
                    .{k.@"1"},
                    0,
                );
                try rootfs_dir.createDirPath(io, target_keep);
                const host_keep = try balloc.printSentinel(
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
            for (spec.tune.io.mount) |m| {
                defer _ = barena.reset(.retain_capacity);
                const target, const mode, const source = m;
                const target_nul = try balloc.dupeSentinel(u8, target, 0);
                switch (mode) {
                    .read, .read_write => {
                        const source_host = try balloc.printSentinel("{s}/{s}", .{ host_cwd, source }, 0);
                        if (cwd.openDir(io, source_host, .{})) |d| {
                            d.close(io);
                            rootfs_dir.createDirPath(io, target) catch {};
                        } else |_| {
                            if (std.fs.path.dirname(target)) |p|
                                rootfs_dir.createDirPath(io, p) catch {};
                            rootfs_dir.writeFile(io, .{ .data = "", .sub_path = target }) catch {};
                        }
                        try mount.bind(
                            source_host,
                            target_nul,
                            .{ .read_only = (mode == .read), .allow_exec = true },
                        );
                    },
                    .tmpfs => {
                        rootfs_dir.createDirPath(io, target) catch {};
                        try mount.mount_fs(
                            "tmpfs",
                            target_nul,
                            "tmpfs",
                            "mode=1777",
                            true,
                        );
                    },
                }
            }
        }

        l.debug("sandbox filesystem ready", .{}); //debug
        try mount.lock_read_only(".");
        try mount.pivot_root(".");
        if (std.os.linux.errno(std.os.linux.chdir("/work")) != .SUCCESS)
            return error.ChdirFailed;
    } else {
        if (!isolate.pid)
            _ = std.os.linux.setsid();
        if (isolate.net and spec.tune.net.private) {
            if (std.os.linux.errno(std.os.linux.unshare(std.os.linux.CLONE.NEWNET)) != .SUCCESS)
                return error.UnshareFailed;
        }

        cwd.createDirPath(io, "/nix") catch {};
        cwd.symLink(io, paths.weft_nix_store, "/nix/store", .{ .is_directory = true }) catch |e|
            if (e != error.PathAlreadyExists) {};

        var rootfs_dir = try cwd.openDir(io, rootfs_path, .{});
        defer rootfs_dir.close(io);

        const script = spec.script orelse no_run_script;
        try rootfs_dir.writeFile(io, .{
            .data = script,
            .sub_path = "entry",
            .flags = .{ .permissions = .executable_file },
        });

        try rootfs_dir.createDirPath(io, "in");
        for (spec.inputs) |inp| {
            defer _ = barena.reset(.retain_capacity);
            const host_in = try balloc.printSentinel(paths.artifact, task.id.w_d(inp), 0);
            const target_in = try balloc.printSentinel("in/{s}", .{inp}, 0);
            _ = std.os.linux.symlinkat(host_in.ptr, rootfs_dir.handle, target_in.ptr);
        }

        try rootfs_dir.createDirPath(io, "out");
        for (spec.outputs) |out| {
            defer _ = barena.reset(.retain_capacity);
            const host_out = try balloc.printSentinel(paths.scratch_output, task.id.wpd_(out), 0);
            const target_out = try balloc.printSentinel("out/{s}", .{out}, 0);
            _ = std.os.linux.symlinkat(host_out.ptr, rootfs_dir.handle, target_out.ptr);
        }

        var cwd_dir = try cwd.openDir(io, host_cwd, .{});
        defer cwd_dir.close(io);
        const root_dir = try cwd.openDir(io, "/", .{});
        defer root_dir.close(io);
        for (spec.keep) |k| {
            defer _ = barena.reset(.retain_capacity);
            const host_keep = try balloc.printSentinel(paths.keep, task.id.w_(k.@"0"), 0);
            const target_keep = try balloc.printSentinel("{s}", .{k.@"1"}, 0);
            _ = std.os.linux.symlinkat(host_keep.ptr, cwd_dir.handle, target_keep.ptr);
        }
        for (spec.tune.io.mount) |m| {
            defer _ = barena.reset(.retain_capacity);
            const target, const mode, const source = m;
            const target_nul = try balloc.dupeSentinel(u8, target, 0);
            if (std.fs.path.dirname(target)) |p|
                cwd_dir.createDirPath(io, p) catch {};
            switch (mode) {
                .read, .read_write => {
                    const source_nul = try balloc.dupeSentinel(u8, source, 0);
                    _ = std.os.linux.symlinkat(source_nul.ptr, cwd_dir.handle, target_nul.ptr);
                },
                .tmpfs => {
                    var rand: [1 << 5]u8 = undefined;
                    io.random(&rand);
                    const tmp_path = try balloc.printSentinel("/tmp/weft-tmp/{s}", .{&std.fmt.bytesToHex(rand, .lower)}, 0);
                    cwd.createDirPath(io, "/tmp/weft-tmp") catch {};
                    cwd.createDirPath(io, tmp_path) catch {};
                    _ = std.os.linux.symlinkat(tmp_path.ptr, cwd_dir.handle, target_nul.ptr);
                },
            }
        }

        if (std.os.linux.errno(std.os.linux.chdir(host_cwd.ptr)) != .SUCCESS)
            return error.ChdirFailed;
    }

    l.debug("dropping privileges to uid {d}", .{uid});
    if (std.os.linux.errno(std.os.linux.syscall2(.setgroups, 0, 0)) != .SUCCESS)
        return error.SetGroupsFailed;
    if (std.os.linux.errno(std.os.linux.setresgid(uid, uid, uid)) != .SUCCESS)
        return error.SetGidFailed;
    if (std.os.linux.errno(std.os.linux.setresuid(uid, uid, uid)) != .SUCCESS)
        return error.SetUidFailed;
    if (std.os.linux.errno(std.os.linux.prctl(@backingInt(std.os.linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS)
        return error.NoNewPrivsFailed;

    var env_map = env_map: {
        var env_map: std.process.Environ.Map = .init(gpa);
        errdefer env_map.deinit();

        var path_writer: std.Io.Writer.Allocating = .init(gpa);
        defer path_writer.deinit();

        for (spec.pkgs) |pkg|
            try path_writer.writer.print("/nix/store/{s}/bin:", .{pkg});

        if (isolate.mount)
            try path_writer.writer.writeAll("/bin")
        else
            try path_writer.writer.writeAll(paths.weft_bin ++ ":/usr/bin:/bin");
        try path_writer.writer.flush();

        const home_val = if (isolate.mount)
            try alloc.print("/home/{s}", .{username})
        else
            host_home;

        try env_map.put("PATH", try path_writer.toOwnedSlice());
        try env_map.put("HOME", home_val);
        try env_map.put("USER", username);
        try env_map.put("LOGNAME", username);
        try env_map.put("TMPDIR", "/tmp");
        try env_map.put("IN", if (isolate.mount) "/in" else try alloc.print("{s}in", .{rootfs_path}));
        try env_map.put("OUT", if (isolate.mount) "/out" else try alloc.print("{s}out", .{rootfs_path}));
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
    l.debug("environment ready, spawning entry", .{}); //debug

    const entry_path = if (isolate.mount)
        "/entry"
    else
        try alloc.print("{s}entry", .{rootfs_path});

    _ = barena.reset(.free_all);
    const child = try std.process.spawn(io, .{
        .argv = &.{entry_path},
        .environ_map = &env_map,
    });
    const child_pid = child.id orelse unreachable;

    var status: u32 = 0;
    while (true) {
        const done = std.os.linux.waitpid(-1, @ptrCast(&status), 0); // takes i32 for status
        if (std.os.linux.errno(done) == .INTR)
            continue;
        l.debug("reaped pid {d}", .{done}); //debug
        if (done == child_pid) {
            const code: u8 = if (std.os.linux.W.IFEXITED(status))
                std.os.linux.W.EXITSTATUS(status)
            else
                128 + @as(u8, @truncate(@backingInt(std.os.linux.W.TERMSIG(status))));
            if (code != 0)
                l.err("task exited with code {d}", .{code})
            else
                l.info("task exited successfully", .{});
            std.os.linux.exit_group(code);
        }
    }
}
