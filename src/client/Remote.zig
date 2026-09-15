const std = @import("std");

name: ?[]const u8 = null,
address: struct { []const u8, u16 } = .{ "127.0.0.1", 9338 },
token: []const u8,

pub fn get_token(self: @This()) ![32]u8 {
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, self.token);
    return out;
}
pub fn get_address(self: @This()) !std.Io.net.IpAddress {
    return try .parse(self.address.@"0", self.address.@"1");
}
pub fn get_name(self: @This()) []const u8 {
    return self.name orelse "local";
}
