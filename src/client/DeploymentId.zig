const std = @import("std");

const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const epoch_ms: u64 = 1_767_225_600_000;

const decode_table: [128]u8 = blk: {
    var table: [128]u8 = @splat(255);
    for (alphabet, 0..) |c, idx|
        table[c] = @intCast(idx);

    break :blk table;
};

raw: u64,

pub fn now(io: std.Io) !@This() {
    const wall_ms = @as(u64, @intCast(std.Io.Clock.now(.real, io).toMilliseconds()));
    const ms_since_epoch = if (wall_ms > epoch_ms) wall_ms - epoch_ms else 0;
    const ticks = ms_since_epoch / 100;
    var salt: [2]u8 = undefined;
    try io.randomSecure(&salt);
    const salt_u15: u64 = std.mem.readInt(u16, &salt, .little) & 0x7FFF;

    return .{
        .raw = (ticks << 15) | salt_u15,
    };
}

pub fn to_string(self: @This()) [8]u8 {
    var buf: [8]u8 = undefined;
    var v = self.raw;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        buf[i] = alphabet[@as(usize, @intCast(v % alphabet.len))];
        v /= alphabet.len;
    }
    return buf;
}
pub fn to_string_alloc(self: @This(), gpa: std.mem.Allocator) ![]u8 {
    const val = try gpa.alloc(u8, 8);
    errdefer gpa.free(val);
    @memcpy(val, &self.to_string());
    return val;
}

pub fn parse(str: []const u8) !@This() {
    if (str.len != 8)
        return error.InvalidLength;
    var val: u64 = 0;
    for (str) |c| {
        if (c >= 128)
            return error.InvalidCharacter;
        const digit = decode_table[c];
        if (digit == 255)
            return error.InvalidCharacter;
        val = val * alphabet.len + digit;
    }
    return .{ .raw = val };
}

pub fn format(self: @This(), writer: *std.Io.Writer) !void {
    try writer.writeAll(&self.to_string());
}

pub fn formatNumber(self: @This(), writer: *std.Io.Writer, num: std.fmt.Number) !void {
    _ = num;
    return self.format(writer);
}
