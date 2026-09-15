const std = @import("std");

pub const Remote = @import("Remote.zig");
const Term = @import("Term.zig");
const UUIDv7 = @import("UUIDv7.zig");

pub const read_only_user_permissions = @as(std.Io.File.Permissions, @enumFromInt(@as(u32, std.os.linux.S.IRUSR | std.os.linux.S.IWUSR)));
pub const read_only_user_mode = read_only_user_permissions.toMode();
pub const remotes_zon_file_name = "remotes.zon";

config_dir: std.Io.Dir,
data_dir: std.Io.Dir,
temp_dir: std.Io.Dir,

pub fn init(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !@This() {
    const config_dir = try open_config_dir(alloc, io, env);
    const data_dir = try open_data_dir(alloc, io, env);

    data_dir.createDirPath(io, "temp") catch {};
    const temp_dir = try data_dir.openDir(io, "temp", .{ .iterate = true });

    return .{
        .config_dir = config_dir,
        .data_dir = data_dir,
        .temp_dir = temp_dir,
    };
}
pub fn open_temp(self: @This(), io: std.Io, sub: []const u8) !std.Io.Dir {
    const uuid = (try UUIDv7.now(io)).to_string();

    self.temp_dir.createDirPath(io, sub) catch {};
    var sub_dir = try self.temp_dir.openDir(io, sub, .{});
    defer sub_dir.close(io);

    try sub_dir.createDirPath(io, &uuid);
    return try sub_dir.openDir(io, &uuid, .{});
}

pub fn open_config_dir(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !std.Io.Dir {
    const path = try if (env.get("XDG_CONFIG_HOME")) |xdg|
        std.fs.path.join(alloc, &.{ xdg, "weft" })
    else if (env.get("HOME")) |home|
        std.fs.path.join(alloc, &.{ home, ".config", "weft" })
    else
        return error.NoHomeFound;
    defer alloc.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

pub fn open_data_dir(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !std.Io.Dir {
    const path = try if (env.get("HOME")) |home|
        std.fs.path.join(alloc, &.{ home, ".weft" })
    else
        return error.NoHomeFound;
    defer alloc.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

pub fn get_remotes(self: @This(), alloc: std.mem.Allocator, io: std.Io, term: *Term) ![]Remote {
    const content = self.config_dir.readFileAllocOptions(
        io,
        remotes_zon_file_name,
        alloc,
        .unlimited,
        .of(u8),
        0,
    ) catch |err|
        return if (err == error.FileNotFound)
            &.{}
        else
            err;
    defer alloc.free(content);
    var diag: std.zon.parse.Diagnostics = .{};

    return std.zon.parse.fromSliceAlloc([]Remote, alloc, content, &diag, .{}) catch |err| {
        try diag.format(term.writer());
        term.flush() catch {};
        return err;
    };
}
