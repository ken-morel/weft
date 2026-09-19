const std = @import("std");

alloc: std.mem.Allocator,
screen: [][]u8,

pub fn init(alloc: std.mem.Allocator) !@This() {
    return .{ .alloc = alloc };
}
