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
    const content = try self.dir.readFileAllocOptions(
        io,
        "weft.zon",
        alloc,
        .limited(4 << 10),
        .of(u8),
        0,
    );
    return try std.zon.parse.fromSliceAlloc(Weft, alloc, content, null, .{});
}

pub fn open_weft_dir(self: *const @This(), io: std.Io) !std.Io.Dir {
    self.dir.createDirPath(
        io,
        ".weft",
    ) catch |err|
        if (err != error.PathAlreadyExists)
            return err;
    return self.dir.openDir(io, ".weft", .{ .iterate = true });
}
pub fn open_deployment_dir(self: *const @This(), io: std.Io, deployment: UUIdv7) !std.Io.Dir {
    const weft_dir = try self.open_weft_dir(io);
    defer weft_dir.close(io);

    var deployment_name: [36]u8 = undefined;
    try deployment.to_string(&deployment_name);

    weft_dir.createDirPath(
        io,
        &deployment_name,
    ) catch |err|
        if (err != error.PathAlreadyExists)
            return err;
    return weft_dir.openDir(io, &deployment_name, .{ .iterate = true });
}
