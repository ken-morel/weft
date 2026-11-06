const std = @import("std");

const Task = @import("../daemon/Task.zig");
const paths = @import("../domain/paths.zig");
const mount = @import("mount.zig");

const no_run_script = "#!/bin/env -S weft nop";

pub fn build_env_map(
    alloc: std.mem.Allocator,
    username: []const u8,
    spec: Task.Spec,
) !std.process.Environ.Map {
    var env_map: std.process.Environ.Map = .init(alloc);

    // 1. Build PATH from spec.pkgs + /bin
    var path_buf: std.ArrayListUnmanaged(u8) = .empty;
    for (spec.pkgs) |pkg| {
        // Assuming pkg is the store folder name (e.g. "xxxx-ripgrep-14.1.0")
        try path_buf.writer(alloc).print("/nix/store/{s}/bin:", .{pkg});
    }
    try path_buf.appendSlice(alloc, "/bin");

    const home_val = try std.fmt.allocPrint(alloc, "/home/{s}", .{username});

    // 2. Core sandbox environment variables
    try env_map.put("PATH", path_buf.items);
    try env_map.put("HOME", home_val);
    try env_map.put("USER", username);
    try env_map.put("LOGNAME", username);
    try env_map.put("TMPDIR", "/tmp");
    try env_map.put("IN", "/in");
    try env_map.put("OUT", "/out");
    try env_map.put("WEFT_MODE", spec.mode);

    // 3. User-defined pipeline variables from spec.vars
    for (spec.vars) |kv| {
        try env_map.put(kv.@"0", kv.@"1");
    }

    return env_map;
}

pub fn spawn(gpa: std.mem.Allocator, io: std.Io, task: Task) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const spec = try task.read_spec(gpa, alloc, io);
    const workspace = task.get_workspace();
    const uid = try workspace.uid(alloc, io);
    const username = "weft";

    const dep_str = task.id.deployment.to_string();
    const rootfs_path = try std.fmt.allocPrintSentinel(alloc, paths.task_run_root, .{
        task.id.workspace, task.id.pipeline, &dep_str,
    }, 0);

    // 1. Unshare namespaces
    var flags: usize = mount.CLONE.NEWNS | mount.CLONE.NEWUTS | mount.CLONE.NEWIPC | mount.CLONE.NEWCGROUP;
    if (spec.tune.net.private)
        flags |= mount.CLONE.NEWNET;

    if (std.os.linux.errno(std.os.linux.unshare(flags)) != .SUCCESS)
        return error.UnshareFailed;

    // 2. Isolate mount table & mount tmpfs on rootfs_path
    try mount.isolate();
    try mount.mount_tmpfs(rootfs_path, "size=16m,mode=0755", true);

    var rootfs_dir = try std.Io.Dir.cwd().openDir(io, rootfs_path, .{});

    // 3. Populate rootfs skeleton in RAM
    const user_home_rel = try std.fmt.allocPrintSentinel(alloc, "home/{s}", .{username}, 0);
    for ([_][]const u8{
        "nix/store", "bin", "usr", "proc", "tmp", "dev/shm", "etc", "work", "in", "out", user_home_rel,
    }) |dir| {
        try rootfs_dir.createDirPath(io, dir);
    }

    _ = std.os.linux.symlinkat("/bin", rootfs_dir.handle, "usr/bin");

    // Write /entry directly into rootfs tmpfs
    const script = spec.script orelse no_run_script;
    try rootfs_dir.writeFile(io, .{
        .data = script,
        .sub_path = "entry",
        .flags = .{ .permissions = .executable_file },
    });

    // Write virtual /etc/passwd and /etc/group
    const passwd = try std.fmt.allocPrint(
        alloc,
        "root:x:0:0:root:/root:/bin/sh\n{s}:x:{d}:{d}:{s}:/home/{s}:/bin/sh\nnobody:x:65534:65534:nobody:/nonexistent:/bin/false\n",
        .{ username, uid, uid, username, username },
    );
    try rootfs_dir.writeFile(io, .{ .data = passwd, .sub_path = "etc/passwd" });

    const group = try std.fmt.allocPrint(alloc, "root:x:0:\n{s}:x:{d}:\nnobody:x:65534:\n", .{ username, uid });
    try rootfs_dir.writeFile(io, .{ .data = group, .sub_path = "etc/group" });

    // 4. Perform all mounts relative to rootfs_path
    if (std.os.linux.errno(std.os.linux.chdir(rootfs_path.ptr)) != .SUCCESS) return error.ChdirFailed;

    try mount.bind(paths.weft_nix_store, "nix/store", .{ .read_only = true, .allow_exec = true });
    try mount.bind(paths.weft_bin, "bin", .{ .read_only = true, .allow_exec = true });

    if (!spec.tune.net.private) {
        try rootfs_dir.writeFile(io, .{ .data = "", .sub_path = "etc/resolv.conf" });
        try mount.bind("/etc/resolv.conf", "etc/resolv.conf", .{ .read_only = true });
    }

    // Bind /var/lib/weft/workspace/{w}/home/ -> home/weft
    const host_home = try std.fmt.allocPrintSentinel(alloc, paths.workspace_home, .{task.id.workspace}, 0);
    try mount.bind(host_home, user_home_rel, .{ .read_only = false, .allow_exec = true });

    // Bind /var/lib/weft/workspace/{w}/scratch/{p}/{d}/cwd/ -> work
    const host_cwd = try std.fmt.allocPrintSentinel(alloc, paths.scratch_cwd, .{
        task.id.workspace, task.id.pipeline, &dep_str,
    }, 0);
    try mount.bind(host_cwd, "work", .{ .read_only = false, .allow_exec = true });

    // Virtual filesystems & character devices
    try mount.mount_proc("proc");
    try mount.mount_tmpfs("tmp", "mode=1777", true);
    try mount.mount_tmpfs("dev/shm", "mode=1777", false);

    inline for (.{ "null", "zero", "full", "random", "urandom", "tty" }) |dev| {
        try rootfs_dir.writeFile(io, .{ .data = "", .sub_path = "dev/" ++ dev });
        try mount.bind("/dev/" ++ dev, "dev/" ++ dev, .{ .read_only = false, .allow_dev = true });
    }

    // Bind inputs (Read-Only): /var/lib/weft/workspace/{w}/artifact/{inp}/latest -> in/{inp}
    for (spec.inputs) |inp| {
        const target_in = try std.fmt.allocPrintSentinel(alloc, "in/{s}", .{inp}, 0);
        try rootfs_dir.createDirPath(io, target_in);
        const host_in = try std.fmt.allocPrintSentinel(alloc, paths.artifact_latest, .{
            task.id.workspace, inp,
        }, 0);
        try mount.bind(host_in, target_in, .{ .read_only = true, .allow_exec = true });
    }

    // Bind outputs (Read-Write): /var/lib/weft/workspace/{w}/scratch/{p}/{d}/out/{out}/ -> out/{out}
    for (spec.outputs) |out| {
        const target_out = try std.fmt.allocPrintSentinel(alloc, "out/{s}", .{out}, 0);
        try rootfs_dir.createDirPath(io, target_out);
        const host_out = try std.fmt.allocPrintSentinel(alloc, paths.scratch_output, .{
            task.id.workspace, task.id.pipeline, &dep_str, out,
        }, 0);
        try mount.bind(host_out, target_out, .{ .read_only = false, .allow_exec = true });
    }

    // Bind keep directories: /var/lib/weft/workspace/{w}/keep/{k.0}/ -> work/{k.1}
    for (spec.keep) |k| {
        const target_keep = try std.fmt.allocPrintSentinel(alloc, "work/{s}", .{k.@"1"}, 0);
        try rootfs_dir.createDirPath(io, target_keep);
        const host_keep = try std.fmt.allocPrintSentinel(alloc, paths.keep, .{
            task.id.workspace, k.@"0",
        }, 0);
        try mount.bind(host_keep, target_keep, .{ .read_only = false, .allow_exec = true });
    }

    rootfs_dir.close(io);

    // 5. Lock "/" as Read-Only and pivot_root
    try mount.lock_read_only(".");
    try mount.pivot_root(".");
    _ = std.os.linux.chdir("/work");

    // 6. Drop privileges to workspace UID/GID
    _ = std.os.linux.syscall2(.setgroups, 0, 0);
    if (std.os.linux.errno(std.os.linux.setresgid(uid, uid, uid)) != .SUCCESS) return error.SetGidFailed;
    if (std.os.linux.errno(std.os.linux.setresuid(uid, uid, uid)) != .SUCCESS) return error.SetUidFailed;
    _ = std.os.linux.prctl(@backingInt(std.os.linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);

    // 7. Spawn /entry as PID 2 using std.process.spawn!
    var env_map = try build_env_map(alloc, username, spec);
    defer env_map.deinit();

    const child = try std.process.spawn(io, .{
        .argv = &.{"/entry"},
        .environ_map = &env_map,
    });
    const child_pid: usize = @intCast(child.id orelse unreachable);

    // 8. PID 1 Zombie Reaping Loop
    var status: u32 = 0;
    while (true) {
        const done = std.os.linux.waitpid(-1, &status, 0);
        if (std.os.linux.errno(done) == .INTR) continue;
        if (done == child_pid) {
            const code: u8 = if (std.os.linux.W.IFEXITED(status))
                std.os.linux.W.EXITSTATUS(status)
            else
                128 + @as(u8, @intCast(std.os.linux.W.TERMSIG(status)));
            std.os.linux.exit_group(code);
        }
    }
}
