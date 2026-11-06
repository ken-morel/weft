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
