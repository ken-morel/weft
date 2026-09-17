const std = @import("std");

const UUIDv7 = @import("../util/UUIDv7.zig");

pub const var_lib = "/var/lib/";

pub inline fn state_dir(path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, var_lib))
        path[var_lib.len..]
    else
        @panic("State directory must be a child of /var/lib");
}

pub const weft_dir = var_lib ++ "weft/";
pub const weft_artifacts_dir = weft_dir ++ "artifacts/";
pub const weft_run_dir = weft_dir ++ "run/";
pub const weft_archive = weft_dir ++ "archive/";
pub const weft_cache_dir = weft_dir ++ "cache/";

pub const weft_socket = "/tmp/weft.sock";

pub inline fn artifact(
    alloc: std.mem.Allocator,
    w: []const u8,
    s: []const u8,
    e: []const u8,
    d: []const u8,
    p: []const u8,
) ![]u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_artifacts_dir, w, s, e, d, p },
    );
}
pub inline fn artifacts(
    alloc: std.mem.Allocator,
    w: []const u8,
    s: []const u8,
    e: []const u8,
    d: []const u8,
) ![]u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_artifacts_dir, w, s, e, d },
    );
}

pub inline fn run(
    alloc: std.mem.Allocator,
    w: []const u8,
    s: []const u8,
    e: []const u8,
    d: []const u8,
    p: []const u8,
) ![]u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_run_dir, w, s, e, p, d },
    );
}

pub inline fn task_archive(
    alloc: std.mem.Allocator,
    w: []const u8,
    s: []const u8,
    e: []const u8,
    d: []const u8,
    p: []const u8,
) ![]const u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_archive, w, s, e, d, p },
    );
}

pub inline fn task_cache(
    alloc: std.mem.Allocator,
    w: []const u8,
    s: []const u8,
    e: []const u8,
    p: []const u8,
    k: []const u8,
) ![]const u8 {
    return try std.fs.path.join(
        alloc,
        &.{ weft_cache_dir, "pipelines", w, s, e, p, k },
    );
}
