const std = @import("std");
const builtin = @import("builtin");

pub const read_only_user_permissions = if (builtin.os.tag == .linux)
    @as(std.Io.File.Permissions, @fromBackingInt(@intCast(@as(u32, std.os.linux.S.IRUSR | std.os.linux.S.IWUSR))))
else {};

pub fn write_file_atomic(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    content: []const u8,
    opts: struct {
        replace: bool = false,
        permissions: std.Io.File.Permissions = .default_file,
    },
) !void {
    var atomic = try dir.createFileAtomic(io, path, .{
        .replace = opts.replace,
        .permissions = opts.permissions,
    });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, content, 0);
    if (opts.replace)
        try atomic.replace(io)
    else
        try atomic.link(io);
}

pub fn spawn_detach(io: std.Io, spawn_options: std.process.SpawnOptions) !void {
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

        _ = std.process.spawn(io, spawn_options) catch |err| {
            _ = std.os.linux.write(std.posix.STDERR_FILENO, "spawn_detach failed: ", "spawn_detach failed: ".len);
            _ = std.os.linux.write(std.posix.STDERR_FILENO, @errorName(err).ptr, @errorName(err).len);
            _ = std.os.linux.write(std.posix.STDERR_FILENO, "\n", 1);
            if (@errorReturnTrace()) |trace|
                std.debug.dumpErrorReturnTrace(trace);
            std.os.linux.exit_group(1);
        };
        std.os.linux.exit_group(0);
    } else {
        var status: i32 = 0;
        _ = std.os.linux.waitpid(@intCast(pid), &status, 0);
    }
}

pub fn chown(parent: std.Io.Dir, sub_path: [:0]const u8, uid: u32, gid: u32) !void {
    const log = std.log.scoped(.domain_chown);
    const errno = std.os.linux.errno(std.os.linux.fchownat(parent.handle, sub_path.ptr, uid, gid, 0));
    if (errno != .SUCCESS) {
        log.err("Chown on {s} to {d}:{d} failed with errno {any}", .{ sub_path, uid, gid, errno });
        return error.ChownFailed;
    }
}

/// Like createDirPath, but every component of `sub_path` ends up owned by uid:uid.
pub fn create_dir_path_owned(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, uid: u32) !void {
    try dir.createDirPath(io, sub_path);
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var end: usize = 0;
    while (end < sub_path.len) {
        end = std.mem.findScalarPos(u8, sub_path, end + 1, '/') orelse sub_path.len;
        if (end > buf.len - 1)
            return error.NameTooLong;
        @memcpy(buf[0..end], sub_path[0..end]);
        buf[end] = 0;
        try chown(dir, buf[0..end :0], uid, uid);
    }
}
