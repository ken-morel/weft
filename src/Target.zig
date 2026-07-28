const NumPattern = @import("numpattern.zig").NumPattern;
const std = @import("std");

remote: ?[]const u8,
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
        .remote = remote,
        .pipeline = slice,
        .exit_code = exit_code,
    };
}
pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
    if (self.remote) |remote|
        alloc.free(remote);
    if (self.exit_code) |exit|
        exit.deinit(alloc);
    alloc.free(self.pipeline);
}
