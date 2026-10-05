const std = @import("std");

const Term = @import("../domain/Term.zig");
const Deployment = @import("Deployment.zig");
pub const Remote = @import("Remote.zig");

pub const read_only_user_permissions = @as(std.Io.File.Permissions, @fromBackingInt(@intCast(@as(u32, std.os.linux.S.IRUSR | std.os.linux.S.IWUSR))));
pub const read_only_user_mode = read_only_user_permissions.toMode();
pub const remotes_zon_file_name = "remotes.zon";

config_dir: std.Io.Dir,
data_dir: std.Io.Dir,
temp_dir: std.Io.Dir,

pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !@This() {
    const config_dir = try open_config_dir(gpa, io, env);
    const data_dir = try open_data_dir(gpa, io, env);

    data_dir.createDirPath(io, "temp") catch {};
    const temp_dir = try data_dir.openDir(io, "temp", .{ .iterate = true });

    return .{
        .config_dir = config_dir,
        .data_dir = data_dir,
        .temp_dir = temp_dir,
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

pub fn get_remotes_leaky(self: @This(), gpa: std.mem.Allocator, io: std.Io) ![]Remote {
    const content = self.config_dir.readFileAllocOptions(
        io,
        remotes_zon_file_name,
        gpa,
        .unlimited,
        .of(u8),
        0,
    ) catch |err|
        return if (err == error.FileNotFound)
            &.{}
        else
            err;
    defer gpa.free(content);
    var diag: std.zon.parse.Diagnostics = .{ .errors = &.{undefined} };

    return std.zon.parse.fromSlice([]Remote, .{
        .gpa = gpa,
        .arena = gpa,
        .source = content,
        .diagnostics = &diag,
    }) catch |err| {
        diag.log(remotes_zon_file_name);
        return err;
    };
}

pub fn save_remotes(self: @This(), io: std.Io, remotes: []const Remote) !void {
    var atomic = try self.config_dir.createFileAtomic(io, remotes_zon_file_name, .{
        .permissions = read_only_user_permissions,
        .replace = true,
    });
    defer atomic.deinit(io);
    var buffer: [4 << 10]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try std.zon.stringify.serialize(remotes, .{}, &writer.interface);
    try writer.interface.flush();
    try atomic.replace(io);
}
