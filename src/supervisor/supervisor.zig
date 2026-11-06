const std = @import("std");

const Task = @import("../daemon/Task.zig");
const domain = @import("../domain/domain.zig");
const paths = @import("../domain/paths.zig");
const nix = @import("../nix/nix.zig");
const CGroup2 = @import("../util/CGroup2.zig");
const zoto = @import("../util/zoto.zig");
const mount = @import("mount.zig");

const default_max_pids = 256;

pub fn spawn_supervisor(io: std.Io, id: Task.Id) !void {
    _ = try std.process.spawn(io, .{
        .argv = &.{
            "/proc/self/exe",
            "daemon",
            "supervise",
            id.workspace,
            id.pipeline,
            &id.deployment.to_string(),
        },
    });
}

fn chown(parent: std.Io.Dir, sub_path: [:0]const u8, uid: u32, gid: u32) !void {
    const rc = std.os.linux.fchownat(parent.handle, sub_path.ptr, uid, gid, 0);
    if (std.os.linux.errno(rc) != .SUCCESS)
        return error.ChownFailed;
}

fn freeze_dir(io: std.Io, dir: std.Io.Dir) !void {
    _ = std.os.linux.fchown(dir.handle, 0, 0);
    _ = std.os.linux.fchmod(dir.handle, 0o555);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const name_z = try std.posix.toPosixPath(entry.name);
        _ = std.os.linux.fchownat(dir.handle, &name_z, 0, 0, std.os.linux.AT.SYMLINK_NOFOLLOW);

        if (entry.kind == .directory) {
            var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer sub.close(io);
            try freeze_dir(io, sub);
        } else if (entry.kind == .file) {
            var f = try dir.openFile(io, entry.name, .{});
            defer f.close(io);
            _ = std.os.linux.fchmod(f.handle, 0o555);
        }
    }
}

pub fn supervise(gpa: std.mem.Allocator, io: std.Io, task: Task) !void {
    _ = std.os.linux.syscall3(.setpriority, 0, 0, 10);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var barena: std.heap.ArenaAllocator = .init(gpa);
    defer barena.deinit();
    const balloc = arena.allocator();

    const cwd: std.Io.Dir = .cwd();

    const run_dir_path = try alloc.print(paths.task_run, task.wpd());
    const root_path = try alloc.print(paths.task_run_root, task.wpd());
    const task_dir_path = try alloc.print(paths.task, task.wpd());
    const scratch_path = try alloc.print(paths.scratch, .task.wpd());
    const active_link = try alloc.printSentinel(paths.active_link, task.wpd());

    const l = l: {
        const log_path = try balloc.print(paths.task_logs, task.wpd());
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
        defer barena.reset(.free_all);
        try domain.write_file_atomic(
            io,
            cwd,
            try balloc.print(paths.task_run_pid, task.wpd()),
            try balloc.print("{d}", .{std.os.linux.getpid()}),
            .{},
        );
        try task.write_status(gpa, io, .preparing);
        break :write_pid;
    }

    if (spec.pkgs.len > 0) handle_packages: {
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
        defer barena.reset(.free_all);
        const home_path = try balloc.printSentinel(paths.workspace_home, task.w(), 0);
        try cwd.createDirPath(io, home_path);
        try chown(cwd, home_path, uid, uid);

        const cwd_path = try balloc.printSentinel(paths.scratch_cwd, task.wpd());
        try cwd.createDirPath(io, cwd_path);
        try chown(cwd, cwd_path, uid, uid);

        for (spec.outputs) |output| {
            const out_sub = try balloc.printSentinel(paths.scratch_output, task.wpd_(output), 0);
            try cwd.createDirPath(io, out_sub);
            try chown(cwd, out_sub, uid, uid);
        }

        for (spec.keep) |k| {
            const keep_host = try std.fmt.allocPrintSentinel(alloc, paths.keep, task.w_(k), 0);
            try cwd.createDirPath(io, keep_host);
            try chown(cwd, keep_host, uid, uid);
        }
        break :prepare_files;
    }

    const cgroup = try task.cgroup(gpa);
    try cgroup.create(io);
    defer cgroup.destroy(io) catch {};

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

    const skip = handle_siblings: {
        l.info("resolving sibling policies...", .{});

        const do_sibling = spec.sibling;
        if (do_sibling.poll == 0) {
            l.err("task has invalid sibling.poll of {d}", .{do_sibling.poll});
            return error.InvalidSiblingConfig;
        }

        var waited: u32 = 0;
        while (waited < do_sibling.wait) : (waited += do_sibling.poll) {
            var sibling_iter = try task.siblings(gpa, io, false);
            defer sibling_iter.deinit(io);
            const sibling: Task = while (try sibling_iter.next(io)) |sibl| {
                if (try sibl.is_active(gpa, io))
                    break sibl;
            } else break;

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
                while (try siblings.next(io)) |sibling| {
                    if (try sibling.is_active(gpa, io)) {
                        const name = try sibling.cgroup_name(gpa);
                        defer gpa.free(name);
                        l.info("killing active sibling {s}", .{name});
                        try sibling.kill(gpa, io);
                    }
                }
            },
            .fail => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);
                while (try siblings.next(io)) |sibling| {
                    if (try sibling.is_active(gpa, io)) {
                        l.err("sibling is still active after timeout; failing task", .{});
                        try task.write_status(gpa, io, .failed_sibling);
                        return error.SiblingRunning;
                    }
                }
            },
            .skip => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);
                break :handle_siblings while (try siblings.next(io)) |sibling| {
                    if (try sibling.is_active(gpa, io)) {
                        l.info("sibling is active; skipping task", .{});
                        break true;
                    }
                } else false;
            },
        }
        break :handle_siblings false;
    };

    if (skip) {
        l.info("task skipped", .{});
    } else {
        if (std.os.linux.errno(std.os.linux.unshare(mount.CLONE.NEWPID)) != .SUCCESS)
            return error.UnsharePidFailed;

        var child = try std.process.spawn(io, .{
            .argv = &.{
                "/proc/self/exe",
                "supervisor",
                "spawn",
                task.id.workspace,
                task.id.pipeline,
                &dep_str,
            },
            .start_suspended = true,
        });
        const child_pid: std.posix.pid_t = child.id orelse unreachable;

        try cgroup.procs_add(gpa, io, child_pid);

        if (std.os.linux.errno(std.os.linux.kill(child_pid, .CONT)) != .SUCCESS)
            return error.KillContFailed;

        try task.write_status(gpa, io, .running);
        const term = try child.wait(io);
        if (!term.success()) {
            l.err("task failed", .{});

            try task.write_status(gpa, io, .failed);
            return error.TaskFailed;
        }
    }
    try task.write_status(gpa, io, .harvesting);

    const dep_z = try alloc.dupeSentinel([]const u8, &task.deployment.to_string(), 0);

    for (spec.outputs) |output| {
        defer barena.reset(.free_all);
        const out_sub = try balloc.printSentinel(paths.scratch_output, task.wpd_(output), 0);

        {
            var staged = try cwd.openDir(io, out_sub, .{ .iterate = true });
            defer staged.close(io);
            try freeze_dir(io, staged);
        }

        const artifact_path = try balloc.print(paths.artifact, task.w_d(output));

        cwd.deleteTree(
            io,
            artifact_path,
        ) catch |e| if (e != error.FileNotFound)
            return e;

        try cwd.rename(out_sub, cwd, artifact_path, io);
    }

    if (!skip)
        try task.write_status(gpa, io, .{ .sibling = .skipped })
    else
        try task.write_status(gpa, io, .done);

    l.info("task completed and outputs harvested", .{});
}
