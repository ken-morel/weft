const std = @import("std");
const UUIDv7 = @import("../UUIDv7.zig");

const weft_dir = "/var/lib/weft/";
const artifacts_dir = weft_dir ++ "/artifacts/";

pub fn artifact(alloc: std.mem.Allocator, w: []const u8, s: []const u8, e: []const u8, d: UUIDv7, p: []const u8) []const u8 {
    return try std.fs.path.join(
        alloc,
        &.{ w, s, e, d.to_string(), p },
    );
}
