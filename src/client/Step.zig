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

pub fn parse_target(name: []const u8, mode: []const u8) !@This() {
    var m = mode;
    const mode_sep = std.mem.findScalar(u8, name, ':');
    if (mode_sep) |sep|
        m = name[0..sep];
    const slice = if (mode_sep) |sep|
        name[sep + 1 ..]
    else
        name;

    const remote_sep = std.mem.findScalar(u8, slice, '.');
    const remote = if (remote_sep) |sep|
        slice[0..sep]
    else
        "local";
    const pipeline = if (remote_sep) |sep|
        slice[sep + 1 ..]
    else
        slice;
    if (!is_valid_name(m) or !is_valid_name(remote) or !is_valid_name(pipeline))
        return error.InvalidStep;
    return .{
        .mode = m,
        .remote = remote,
        .pipeline = pipeline,
    };
}
