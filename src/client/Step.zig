const std = @import("std");

const Deployment = @import("Deployment.zig");

mode: []const u8,
remote: []const u8,
pipeline: []const u8,

pub fn is_valid_name(str: []const u8) bool {
    return str.len > 0 and
        std.ascii.isAlphabetic(str[0]) and
        for (str[1..]) |c|
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_')
                break false
            else {}
        else
            true;
}

pub fn eq(a: @This(), b: @This()) bool {
    if (!std.mem.eql(u8, a.pipeline, b.pipeline))
        return false
    else
        return std.mem.eql(u8, a.remote, b.remote);
}
