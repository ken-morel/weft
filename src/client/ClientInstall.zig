const std = @import("std");

const Term = @import("../domain/Term.zig");
const Identity = @import("../wire/Identity.zig");
const Deployment = @import("Deployment.zig");

pub const read_only_user_permissions = @as(std.Io.File.Permissions, @fromBackingInt(@intCast(@as(u32, std.os.linux.S.IRUSR | std.os.linux.S.IWUSR))));

pub const key_file_name = "key";

config_dir: std.Io.Dir,
data_dir: std.Io.Dir,
temp_dir: std.Io.Dir,
identity: Identity,
env: *const std.process.Environ.Map,

pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !@This() {
    const config_dir = try open_config_dir(gpa, io, env);
    const data_dir = try open_data_dir(gpa, io, env);

    data_dir.createDirPath(io, "temp") catch {};
    const temp_dir = try data_dir.openDir(io, "temp", .{ .iterate = true });

    const identity = try Identity.ensure(io, config_dir, key_file_name);

    return .{
        .config_dir = config_dir,
        .data_dir = data_dir,
        .temp_dir = temp_dir,
        .identity = identity,
        .env = env,
    };
}
pub fn open_temp(self: @This(), io: std.Io, sub: []const u8) !std.Io.Dir {
    const uuid = (try Deployment.Id.now(io)).to_string();

    self.temp_dir.createDirPath(io, sub) catch {};
    var sub_dir = try self.temp_dir.openDir(io, sub, .{});
    defer sub_dir.close(io);

    try sub_dir.createDirPath(io, &uuid);
    return try sub_dir.openDir(io, &uuid, .{});
}

pub fn open_config_dir(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !std.Io.Dir {
    const path = try if (env.get("XDG_CONFIG_HOME")) |xdg|
        std.fs.path.join(gpa, &.{ xdg, "weft" })
    else if (env.get("HOME")) |home|
        std.fs.path.join(gpa, &.{ home, ".config", "weft" })
    else
        return error.NoHomeFound;
    defer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

pub fn open_data_dir(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !std.Io.Dir {
    const path = try if (env.get("HOME")) |home|
        std.fs.path.join(gpa, &.{ home, ".weft" })
    else
        return error.NoHomeFound;
    defer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}
