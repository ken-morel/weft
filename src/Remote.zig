const std = @import("std");

name: []const u8,
address: std.Io.net.IpAddress,
token: [32]u8,

pub fn dupe(self: @This(), alloc: std.mem.Allocator) !@This() {
    const name = try alloc.dupe(u8, self.name);

    return .{
        .name = name,
        .address = self.address,
        .token = self.token,
    };
}
pub fn free(self: @This(), alloc: std.mem.Allocator) void {
    alloc.free(self.name);
}
