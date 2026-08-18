const std = @import("std");
const UUIdv7 = @import("UUIDv7.zig");
const Weft = @import("Weft.zig");

dir: std.Io.Dir,

pub fn open(dir: std.Io.Dir) !@This() {
    return .{
        .dir = dir,
    };
}

pub fn get_config(self: @This(), arena: *std.heap.ArenaAllocator, io: std.Io) !Weft {
    const alloc = arena.allocator();
    const content = self.dir.readFileAllocOptions(
        io,
        "weft.zon",
        alloc,
        .limited(4 << 10),
        .of(u8),
        0,
    ) catch |err|
        if (err == error.FileNotFound)
            return error.ConfigNotFound
        else
            return err;
    return try std.zon.parse.fromSliceAlloc(Weft, alloc, content, null, .{});
}

pub fn open_weft_dir(self: @This(), io: std.Io) !std.Io.Dir {
    self.dir.createDirPath(
        io,
        ".weft",
    ) catch |err|
        if (err != error.PathAlreadyExists)
            return err;
    return self.dir.openDir(io, ".weft", .{ .iterate = true });
}
pub fn open_deployment_dir(self: @This(), io: std.Io, deployment: UUIdv7) !std.Io.Dir {
    const weft_dir = try self.open_weft_dir(io);
    defer weft_dir.close(io);

    var deployment_name_buff: [36]u8 = undefined;
    const deployment_name = try deployment.to_string(&deployment_name_buff);

    weft_dir.createDirPath(
        io,
        deployment_name,
    ) catch |err|
        if (err != error.PathAlreadyExists)
            return err;

    return weft_dir.openDir(io, deployment_name, .{ .iterate = true });
}

pub fn artifact_dir_path(self: @This(), alloc: std.mem.Allocator, io: std.Io, deployment: UUIdv7, pipeline: []const u8) ![]const u8 {
    const deployment_dir = try self.open_deployment_dir(io, deployment);
    defer deployment_dir.close(io);

    const deployment_dir_path = try deployment_dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(deployment_dir_path);

    return try std.fs.path.join(
        alloc,
        &.{ deployment_dir_path, "artifacts", pipeline },
    );
}
