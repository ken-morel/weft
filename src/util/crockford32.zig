const std = @import("std");

pub const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";

const decode_table: [128]u8 = blk: {
    var table: [128]u8 = @splat(255);
    for (alphabet, 0..) |c, idx| {
        table[c] = @intCast(idx);
        if (c >= 'a' and c <= 'z')
            table[c - 'a' + 'A'] = @intCast(idx);
    }
    break :blk table;
};

pub inline fn encoded_len(comptime T: type) usize {
    return @divCeil(@bitSizeOf(T), 5);
}

pub fn encode(comptime T: type, value: T) [encoded_len(T)]u8 {
    const len = comptime encoded_len(T);
    var buf: [len]u8 = undefined;
    var v = value;
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        buf[i] = alphabet[@as(usize, @intCast(v & 0x1F))];
        v >>= 5;
    }
    return buf;
}

pub fn decode(comptime T: type, str: []const u8) !T {
    const len = encoded_len(T);
    if (str.len != len)
        return error.InvalidLength;
    var val: T = 0;
    for (str) |c| {
        if (c >= 128)
            return error.InvalidCharacter;
        const digit = decode_table[c];
        if (digit == 255)
            return error.InvalidCharacter;
        val = (val << 5) | @as(T, digit);
    }
    return val;
}
