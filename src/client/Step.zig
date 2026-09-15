const std = @import("std");
const Deployment = @import("Deployment.zig");

remote: []const u8,
pipeline: []const u8,

pub fn parse(txt: []const u8) !@This() {
    var slice = txt;

    var remote: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, slice, '.')) |dot_idx| {
        remote = slice[0..dot_idx];
        slice = slice[dot_idx + 1 ..];
    }

    if (slice.len == 0)
        return error.InvalidTarget;

    return @This(){
        .remote = remote orelse "local",
        .pipeline = slice,
    };
}

pub fn eq(a: @This(), b: @This()) bool {
    if (!std.mem.eql(u8, a.pipeline, b.pipeline))
        return false
    else
        return std.mem.eql(u8, a.remote, b.remote);
}
