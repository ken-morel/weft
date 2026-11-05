const std = @import("std");

const Task = @import("../daemon/Task.zig");
const nix = @import("../nix/nix.zig");
const CGroup2 = @import("../util/CGroup2.zig");
const zoto = @import("../util/zoto.zig");

const no_run_script = "#!/bin/env -S weft nop";
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

pub fn supervise(gpa: std.mem.Allocator, io: std.Io, task: Task) !void {
    std.debug.print("[weft::supervisor] started\n", .{});
    _ = std.os.linux.syscall3(.setpriority, 0, 0, 10);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const alloc = arena.allocator();
    const cwd: std.Io.Dir = .cwd();

    const archive_dir_path = try task.archive_dir_path(alloc);
    const archive_dir = try cwd.createDirPathOpen(io, archive_dir_path, .{});
    defer archive_dir.close(io);

    std.debug.print("[weft::supervisor] redirecting logs to {s}/log.txt\n", .{archive_dir_path});

    const l = l: {
        const log_file = try archive_dir.createFile(io, "log.txt", .{ .truncate = false });
        defer log_file.close(io);
        _ = std.os.linux.dup2(log_file.handle, std.posix.STDOUT_FILENO);
        _ = std.os.linux.dup2(log_file.handle, std.posix.STDERR_FILENO);
        break :l std.log.scoped(.supervisor_supervise);
    };

    l.info("supervisor initialized (nice +10)", .{});

    const run_dir_path = try task.run_dir_path(alloc);
    const run_dir = try std.Io.Dir.cwd().openDir(io, run_dir_path, .{});
    defer run_dir.close(io);

    l.debug("reading {s}/spec...", .{run_dir_path});
    const spec = try task.read_spec(gpa, alloc, io);

    write_pid: {
        const content = try gpa.print("{d}", .{std.os.linux.getpid()});
        defer gpa.free(content);
        try run_dir.writeFile(io, .{ .data = content, .sub_path = "pid" });
        break :write_pid;
    }

    handle_packages: {
        if (spec.pkgs.len > 0) {
            l.info("preparing {d} nix package(s)...", .{spec.pkgs.len});
            var client: std.http.Client = .{
                .io = io,
                .allocator = alloc,
            };
            defer client.deinit();

            for (spec.pkgs) |pkg|
                try nix.install_package(alloc, io, &client, pkg);

            l.info("all nix packages prepared", .{});
        }
        break :handle_packages;
    }

    prepare_files: {
        for (spec.outputs) |output| {
            const output_path = try std.fs.path.join(gpa, &.{ "out", output });
            defer gpa.free(output_path);
            try run_dir.createDirPath(io, output_path);
        }

        const script = spec.script orelse no_run_script;

        try run_dir.writeFile(io, .{
            .data = script,
            .sub_path = "bin",
            .flags = .{ .permissions = .executable_file },
        });
        try run_dir.createDirPath(io, "cwd");
        break :prepare_files;
    }
    const cgroup = try task.cgroup(gpa);
    try cgroup.create(io);
    defer cgroup.destroy(io) catch {};

    configure_cgroup: {
        const tune = &spec.tune;
        if (tune.cpu.quota != null or tune.cpu.max != null)
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
                        return error.AlreadyRunning;
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

    if (!skip) {
        var child = try std.process.spawn(io, .{
            .argv = &.{ "/proc/self/exe", "supervisor", "spawn", task.id.workspace, task.id.pipeline, &task.id.deployment.to_string() },
            .start_suspended = true,
        });
        const child_pid: std.posix.pid_t = child.id orelse unreachable;

        try cgroup.procs_add(gpa, io, child_pid);

        switch (std.os.linux.errno(std.os.linux.kill(child_pid, .CONT))) {
            else => {},
        }

        const term = try child.wait(io);
        if (!term.success())
            return;
    } else {
        l.info("task skipped", .{});
    }
}

pub fn spawn(gpa: std.mem.Allocator, io: std.Io, task: Task) !void {
    const l = std.log.scoped(.supervisor_spawn);
    try io.sleep(.fromSeconds(5), .awake);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const run_dir_path = try task.run_dir_path(alloc);
    const run_dir = try std.Io.Dir.cwd().openDir(io, run_dir_path, .{});
    defer run_dir.close(io);

    l.debug("reading {s}/spec...", .{run_dir_path});
    const spec = try task.read_spec(gpa, alloc, io);
    unshare: {
        var unshare: usize = 0;
        unshare |= CLONE.NEWNS; // new mount namespaces
        unshare |= CLONE.NEWUTS; // new ...
        unshare |= CLONE.NEWIPC; // new ..
        // if (spec.tune.net.private)
        //     unshare |= CLONE.NEWNET; // new network

        switch (std.os.linux.errno(std.os.linux.unshare(unshare))) {
            else => {},
        }
        break :unshare;
    }
    mounts: {
        // switch (std.os.linux.errno(std.os.linux.mount("none", "/", null, MS.REC | MS.PRIVATE, 0))) {
        //     else => {},
        // }
        switch(std.os.linux.errno(std.os.linux.mount()));

        // complete only here
        break :mounts;
    }

    const ret = std.os.linux.execve(try run_dir.realPathFileAlloc(io, "bin", alloc), &.{null}, &.{null});
    _ = ret;
}

pub const CLONE = struct {
    pub const NEWTIME: u32 = 0x00000080;
    pub const VM: u32 = 0x00000100;
    pub const FS: u32 = 0x00000200;
    pub const FILES: u32 = 0x00000400;
    pub const SIGHAND: u32 = 0x00000800;
    pub const PIDFD: u32 = 0x00001000;
    pub const PTRACE: u32 = 0x00002000;
    pub const VFORK: u32 = 0x00004000;
    pub const PARENT: u32 = 0x00008000;
    pub const THREAD: u32 = 0x00010000;
    pub const NEWNS: u32 = 0x00020000;
    pub const SYSVSEM: u32 = 0x00040000;
    pub const SETTLS: u32 = 0x00080000;
    pub const PARENT_SETTID: u32 = 0x00100000;
    pub const CHILD_CLEARTID: u32 = 0x00200000;
    pub const DETACHED: u32 = 0x00400000;
    pub const UNTRACED: u32 = 0x00800000;
    pub const CHILD_SETTID: u32 = 0x01000000;
    pub const NEWCGROUP: u32 = 0x02000000;
    pub const NEWUTS: u32 = 0x04000000;
    pub const NEWIPC: u32 = 0x08000000;
    pub const NEWUSER: u32 = 0x10000000;
    pub const NEWPID: u32 = 0x20000000;
    pub const NEWNET: u32 = 0x40000000;
    pub const IO: u32 = 0x80000000;
};

pub const MS = struct {
    pub const RDONLY = 1;
    pub const NOSUID = 2;
    pub const NODEV = 4;
    pub const NOEXEC = 8;
    pub const SYNCHRONOUS = 16;
    pub const REMOUNT = 32;
    pub const MANDLOCK = 64;
    pub const DIRSYNC = 128;
    pub const NOSYMFOLLOW = 256;
    pub const NOATIME = 1024;
    pub const NODIRATIME = 2048;
    pub const BIND = 4096;
    pub const MOVE = 8192;
    pub const REC = 16384;
    pub const SILENT = 32768;
    pub const POSIXACL = (1 << 16);
    pub const UNBINDABLE = (1 << 17);
    pub const PRIVATE = (1 << 18);
    pub const SLAVE = (1 << 19);
    pub const SHARED = (1 << 20);
    pub const RELATIME = (1 << 21);
    pub const KERNMOUNT = (1 << 22);
    pub const I_VERSION = (1 << 23);
    pub const STRICTATIME = (1 << 24);
    pub const LAZYTIME = (1 << 25);
    pub const NOREMOTELOCK = (1 << 27);
    pub const NOSEC = (1 << 28);
    pub const BORN = (1 << 29);
    pub const ACTIVE = (1 << 30);
    pub const NOUSER = (1U << 31);
    pub const RMT_MASK = (MS_RDONLY | MS_SYNCHRONOUS | MS_MANDLOCK | MS_I_VERSION | MS_LAZYTIME);
    pub const MGC_VAL = 0xc0ed0000;
    pub const MGC_MSK = 0xffff0000;
};
