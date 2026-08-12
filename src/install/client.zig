const std = @import("std");

pub const read_only_user_permissions = @as(std.Io.File.Permissions, @enumFromInt(@as(u32, std.os.linux.S.IRUSR | std.os.linux.S.IWUSR)));
pub const read_only_user_mode = read_only_user_permissions.toMode();
pub const remotes_zon_file_name = "remotes.zon";

pub const Remote = struct {
    name: []const u8,
    address: std.Io.net.IpAddress,
    token: []const u8,

    pub fn dupe(self: @This(), arena: *std.heap.ArenaAllocator) !@This() {
        var buf = try arena.allocator().alloc(u8, self.name.len + self.token.len);

        std.mem.copyForwards(u8, buf[0..self.name.len], self.name);
        std.mem.copyForwards(u8, buf[self.name.len..], self.token);

        return .{
            .name = buf[0..self.name.len],
            .address = self.address,
            .port = self.port,
            .token = buf[self.name.len..],
        };
    }
};

config_dir: std.Io.Dir,

pub fn init(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !@This() {
    const config_dir = try open_config_dir(alloc, io, env);
    const data_dir = try open_data_dir(alloc, io, env);
    defer data_dir.close(io);

    return .{
        .config_dir = config_dir,
    };
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

pub fn get_remotes(self: @This(), arena: *std.heap.ArenaAllocator, io: std.Io) ![]Remote {
    const alloc = arena.allocator();
    const content = self.config_dir.readFileAlloc(
        io,
        remotes_zon_file_name,
        alloc,
        .unlimited,
    ) catch |err|
        return if (err == error.FileNotFound)
            &.{}
        else
            err;
    defer alloc.free(content);
    const null_terminated = try alloc.dupeSentinel(u8, content, 0);
    return std.zon.parse.fromSliceAlloc([]Remote, alloc, null_terminated, null, .{});
}
pub fn get_remote(self: @This(), arena: *std.heap.ArenaAllocator, io: std.Io, name: []const u8) !?Remote {
    const temp_arena: std.heap.ArenaAllocator = .init(arena.allocator());
    defer temp_arena.deinit();

    for (try self.get_remotes(&temp_arena, io)) |remote|
        if (std.mem.eql(u8, remote.name, name))
            return try remote.dupe(&arena);

    return null;
}

pub fn set_remotes(self: @This(), io: std.Io, remotes: []const Remote) !void {
    var atomic = try self.config_dir.createFileAtomic(io, remotes_zon_file_name, .{ .permissions = read_only_user_permissions, .replace = true });
    defer atomic.deinit(io);
    var buffer: [4 << 10]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try std.zon.stringify.serialize(remotes, .{}, &writer.interface);
    try writer.flush();
    try atomic.replace(io);
}

pub fn add_remotes(self: @This(), alloc: std.mem.Allocator, io: std.Io, items: []const Remote) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const aac = arena.allocator();
    const old_remotes = try self.get_remotes(&arena, io);
    const remotes = try aac.realloc(old_remotes, old_remotes.len + items.len);

    std.mem.copyForwards(Remote, remotes[old_remotes.len..], items);
    try self.set_remotes(io, remotes);
}
