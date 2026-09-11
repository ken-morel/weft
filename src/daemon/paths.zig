const std = @import("std");
const UUIDv7 = @import("../UUIDv7.zig");

const weft_dir = "/var/lib/weft/";
const weft_artifacts_dir = weft_dir ++ "artifacts/";
const weft_run_dir = weft_dir ++ "run/";

pub inline fn artifact(
    alloc: std.mem.Allocator,
    w: []const u8,
    s: []const u8,
    e: []const u8,
    d: []const u8,
    p: []const u8,
) []u8 {
    return try std.fs.path.join(
        alloc,
        &.{ w, s, e, d, p },
    );
}
pub inline fn artifacts(
    alloc: std.mem.Allocator,
    w: []const u8,
    s: []const u8,
    e: []const u8,
    d: []const u8,
) []u8 {
    return try std.fs.path.join(
        alloc,
        &.{ w, s, e, d },
    );
}

pub inline fn unit_name(
    alloc: std.mem.Allocator,
    w: []const u8,
    s: []const u8,
    e: []const u8,
    d: []const u8,
    p: []const u8,
) []u8 {
    return try std.mem.join(
        alloc,
        "--",
        &.{
            "weft-runner",
            w,
            e,
            s,
            d,
            p,
        },
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
        &.{
            weft_run_dir,
            w,
            s,
            e,
            d,
            p,
        },
    );
}
