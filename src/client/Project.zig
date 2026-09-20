const std = @import("std");

const Weft = @import("../domain/Weft.zig");
const Deployment = @import("Deployment.zig");

dir: std.Io.Dir,

pub inline fn open(dir: std.Io.Dir) !@This() {
    return .{
        .dir = dir,
    };
}

pub fn get_config(self: @This(), alloc: std.mem.Allocator, io: std.Io) !Weft {
    @setEvalBranchQuota(100_000);
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

pub inline fn open_weft_dir(self: @This(), io: std.Io) !std.Io.Dir {
    return self.dir.createDirPathOpen(io, ".weft", .{ .open_options = .{ .iterate = true } });
}
pub fn open_deployment_dir(self: @This(), io: std.Io, deployment: Deployment.Id) !std.Io.Dir {
    const weft_dir = try self.open_weft_dir(io);
    defer weft_dir.close(io);

    const deployment_name = deployment.to_string();

    weft_dir.createDirPath(
        io,
        &deployment_name,
    ) catch |err|
        if (err != error.PathAlreadyExists)
            return err;

    return weft_dir.openDir(io, &deployment_name, .{ .iterate = true });
}

pub fn artifact_dir_path(self: @This(), alloc: std.mem.Allocator, io: std.Io, deployment_id: Deployment.Id, pipeline: []const u8) ![]const u8 {
    const deployment_dir = try self.open_deployment_dir(io, deployment_id);
    defer deployment_dir.close(io);

    const deployment_dir_path = try deployment_dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(deployment_dir_path);

    return try std.fs.path.join(
        alloc,
        &.{ deployment_dir_path, "artifacts", pipeline },
    );
}

pub fn task_log_path(self: @This(), alloc: std.mem.Allocator, io: std.Io, deployment_id: Deployment.Id, pipeline: []const u8) ![]const u8 {
    const deployment_dir = try self.open_deployment_dir(io, deployment_id);
    defer deployment_dir.close(io);

    const deployment_dir_path = try deployment_dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(deployment_dir_path);

    const log_dir_path = try std.fs.path.join(alloc, &.{ deployment_dir_path, "logs" });
    defer alloc.free(log_dir_path);

    std.Io.Dir.cwd().createDirPath(io, log_dir_path) catch |err|
        if (err != error.PathAlreadyExists)
            return err;

    const filename = try std.fmt.allocPrint(alloc, "{s}.log", .{pipeline});
    defer alloc.free(filename);

    return try std.fs.path.join(
        alloc,
        &.{ log_dir_path, filename },
    );
}
