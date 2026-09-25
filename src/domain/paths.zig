const std = @import("std");

pub inline fn state_dir(path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, var_lib))
        path[var_lib.len..]
    else
        @panic("State directory must be a child of /var/lib");
}

pub const var_lib = "/var/lib/";
pub const weft_dir = var_lib ++ "weft/";
pub const weft_artifacts_dir = weft_dir ++ "artifacts/";
pub const weft_run_dir = weft_dir ++ "run/";
pub const weft_archive = weft_dir ++ "archive/";
pub const weft_cache_dir = weft_dir ++ "cache/";
pub const weft_home_dir = weft_dir ++ "home/";
pub const weft_tmp_dir = weft_dir ++ "tmp/";

pub const weft_runtime_dir = "/run/weft/";
pub const weft_socket = weft_runtime_dir ++ "weft.pipe";

pub fn ensure_dirs(io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, weft_dir) catch {};
    cwd.createDirPath(io, weft_artifacts_dir) catch {};
    cwd.createDirPath(io, weft_run_dir) catch {};
    cwd.createDirPath(io, weft_archive) catch {};
    cwd.createDirPath(io, weft_cache_dir) catch {};
    cwd.createDirPath(io, weft_home_dir) catch {};
    cwd.createDirPath(io, weft_tmp_dir) catch {};
}

pub inline fn home(alloc: std.mem.Allocator, w: []const u8) ![]u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_home_dir, w },
    );
}

pub inline fn artifact(
    alloc: std.mem.Allocator,
    w: []const u8,
    d: []const u8,
    p: []const u8,
) ![]u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_artifacts_dir, w, d, p },
    );
}
pub inline fn artifacts(
    alloc: std.mem.Allocator,
    w: []const u8,
    d: []const u8,
) ![]u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_artifacts_dir, w, d },
    );
}

pub inline fn run(
    alloc: std.mem.Allocator,
    w: []const u8,
    p: []const u8,
    d: []const u8,
) ![]u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_run_dir, w, p, d },
    );
}

pub inline fn task_archive(
    alloc: std.mem.Allocator,
    w: []const u8,
    d: []const u8,
    p: []const u8,
) ![]const u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_archive, w, d, p },
    );
}

pub inline fn task_cache(
    alloc: std.mem.Allocator,
    w: []const u8,
    k: []const u8,
) ![]const u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_cache_dir, w, k },
    );
}
