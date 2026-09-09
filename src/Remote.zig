const std = @import("std");

name: []const u8,
address: std.Io.net.IpAddress,
token: []const u8,

pub fn dupe(self: @This(), alloc: std.mem.Allocator) !@This() {
    var buf = try alloc.alloc(u8, self.name.len + self.token.len);

    std.mem.copyForwards(u8, buf[0..self.name.len], self.name);
    std.mem.copyForwards(u8, buf[self.name.len..], self.token);

    return .{
        .name = buf[0..self.name.len],
        .address = self.address,
        .token = buf[self.name.len..],
    };
}
pub fn free(self: @This(), alloc: std.mem.Allocator) void {
    alloc.free(self.name);
    alloc.free(self.token);
}
