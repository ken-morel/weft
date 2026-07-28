const std = @import("std");
pub const Config = @import("Service.zig");
pub const Parser = @import("Parser.zig");

const weft_data_path = ".weft";

dir: std.Io.Dir,

pub fn open(dir: std.Io.Dir) !@This() {
    return .{
        .dir = dir,
    };
}

pub fn get_config(self: @This(), arena: *std.heap.ArenaAllocator, io: std.Io) !Config {
    const alloc = arena.allocator();
    const content = self.dir.readFileAlloc(io, "service.weft", alloc, .limited(4 << 10)) catch |err| {
        return if (err == error.FileNotFound)
            error.ConfigFileNotFound
        else
            err;
    };
    var parser = Parser.init(alloc, content) orelse return error.EmptyFile;
    return try parser.parse_service();
}

pub fn open_data_dir(self: *const @This(), io: std.Io) !std.Io.Dir {
    try std.Io.Dir.cwd().createDirPath(io, weft_data_path);
    self.dir.createDirPath(
        io,
        ".data",
    ) catch |err|
        if (err != error.PathAlreadyExists)
            return err;
    return self.dir.openDir(io, weft_data_path, .{ .iterate = true });
}
pub fn open_deployments_dir(self: *const @This(), io: std.Io) !std.Io.Dir {
    const data_dir = try self.open_data_dir(io);
    defer data_dir.close(io);
    data_dir.createDirPath(
        io,
        "deployments",
    ) catch |err|
        if (err != error.PathAlreadyExists)
            return err;
    return data_dir.openDir(io, "deployments", .{ .iterate = true });
}

pub fn open_artifacts_dir(self: *const @This(), io: std.Io) !std.Io.Dir {
    const data_dir = try self.open_data_dir(io);
    defer data_dir.close(io);
    data_dir.createDirPath(
        io,
        "atifacts",
    ) catch |err|
        if (err != error.PathAlreadyExists)
            return err;
    return data_dir.openDir(io, "artifacts", .{ .iterate = true });
}
