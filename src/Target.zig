const NumPattern = @import("numpattern.zig").NumPattern;
const std = @import("std");
const Deployment = @import("Deployment.zig");
const Artifact = Deployment.Artifact;
const Running = Deployment.Running;

remote: []const u8,
pipeline: []const u8,
exit_code: ?NumPattern(u8),

pub fn parse(alloc: std.mem.Allocator, txt: []const u8) !@This() {
    var slice = txt;
    var exit_code: ?NumPattern(u8) = null;

    if (std.mem.indexOfScalar(u8, slice, ',')) |comma_idx| {
        const exit_str = slice[comma_idx + 1 ..];
        exit_code = try NumPattern(u8).parse(alloc, exit_str);
        slice = slice[0..comma_idx];
    }
    errdefer if (exit_code) |code|
        code.deinit(alloc);

    var remote: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, slice, '.')) |dot_idx| {
        remote = try alloc.dupe(u8, slice[0..dot_idx]);
        slice = slice[dot_idx + 1 ..];
    }
    errdefer if (remote) |rem|
        alloc.free(rem);

    if (slice.len > 0)
        slice = try alloc.dupe(u8, slice)
    else
        return error.InvalidTarget;
    errdefer alloc.free(slice);

    return @This(){
        .remote = remote orelse try alloc.dupe(u8, "local"),
        .pipeline = slice,
        .exit_code = exit_code,
    };
}
pub fn deinit(self: *const @This(), alloc: std.mem.Allocator) void {
    alloc.free(self.remote);
    if (self.exit_code) |exit|
        exit.deinit(alloc);
    alloc.free(self.pipeline);
}

pub fn could_match(self: @This(), run: Running) bool {
    if (!std.mem.eql(u8, self.pipeline, run.pipeline))
        return false
    else
        return std.mem.eql(u8, self.remote, run.remote);
}

pub fn matches(self: @This(), art: Artifact) bool {
    if (!std.mem.eql(u8, self.pipeline, art.pipeline))
        return false;
    if (self.exit_code) |code|
        if (!code.match(art.exit_code))
            return false;
    if (art.remote) |arem|
        return std.mem.eql(u8, self.remote, arem)
    else
        return false;
}
