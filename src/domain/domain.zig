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
            std.os.linux.exit_group(1);
        };
        std.os.linux.exit_group(0);
    } else {
        var status: i32 = 0;
        _ = std.os.linux.waitpid(@intCast(pid), &status, 0);
    }
}
