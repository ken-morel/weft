const std = @import("std");

const Deployment = @import("Deployment.zig");

remote: []const u8,
pipeline: []const u8,

pub fn parse(txt: []const u8) !@This() {
    var iter = std.mem.splitScalar(u8, txt, '.');

    const remote = iter.next() orelse return error.InvalidStep;
    const pipeline = iter.rest();
    if (pipeline.len == 0 or remote.len == 0)
        return error.InvalidStep;

    return @This(){
        .remote = remote,
        .pipeline = pipeline,
    };
}

pub fn argz_parse(_: std.mem.Allocator, _: ?std.Io, val: []const u8) anyerror!@This() {
    if (val.len > 0 and val[0] == '.') {
        if (val.len == 1) return error.InvalidStep;
        return .{
            .remote = "local",
            .pipeline = val[1..],
        };
    }
    return try parse(val);
}

pub fn eq(a: @This(), b: @This()) bool {
    if (!std.mem.eql(u8, a.pipeline, b.pipeline))
        return false
    else
        return std.mem.eql(u8, a.remote, b.remote);
}
