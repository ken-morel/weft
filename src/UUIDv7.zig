const std = @import("std");

bytes: [16]u8,

pub fn new(io: std.Io) !@This() {
    var bytes: [16]u8 = undefined;

    try io.randomSecure(&bytes);

    const now_ms = std.Io.Clock.now(.awake, io).toMilliseconds();
    std.mem.writeInt(u48, bytes[0..6], @intCast(now_ms), .big);

    bytes[6] = (bytes[6] & 0b00001111) | 0b01110000;
    bytes[8] = (bytes[8] & 0b00111111) | 0b10000000;

    return .{
        .bytes = bytes,
    };
}

pub fn timestamp(self: @This()) u48 {
    return std.mem.readInt(u48, self.bytes[0..6], .big);
}

pub fn rand(self: @This()) struct { u12, u62 } {
    const raw1 = std.mem.readInt(u16, self.bytes[6..8], .big);
    const raw2 = std.mem.readInt(u64, self.bytes[8..16], .big);
    return .{ @intCast(raw1 & 0x0fff), @intCast(raw2 & 0x3fff_ffff_ffff_ffff) };
}

pub fn to_string(self: *const @This(), buf: []u8) ![]const u8 {
    if (buf.len < 36)
        return error.BufferTooSmall;

    return std.fmt.bufPrint(
        buf,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            self.bytes[0],  self.bytes[1],  self.bytes[2],  self.bytes[3],
            self.bytes[4],  self.bytes[5],  self.bytes[6],  self.bytes[7],
            self.bytes[8],  self.bytes[9],  self.bytes[10], self.bytes[11],
            self.bytes[12], self.bytes[13], self.bytes[14], self.bytes[15],
        },
    );
}

pub fn parse(input: []const u8) !@This() {
    if (input.len != 36)
        return error.InvalidLength;

    if (input[8] != '-' or input[13] != '-' or input[18] != '-' or input[23] != '-')
        return error.InvalidCharacter;

    var self: @This() = undefined;
    var out_idx: usize = 0;
    var in_idx: usize = 0;

    while (in_idx < input.len) {
        if (input[in_idx] == '-') {
            in_idx += 1;
            continue;
        }

        const high_nibble = try parse_hex(input[in_idx]);
        const low_nibble = try parse_hex(input[in_idx + 1]);

        self.bytes[out_idx] = (high_nibble << 4) | low_nibble;
        out_idx += 1;
        in_idx += 2;
    }

    return self;
}

pub inline fn parse_hex(c: u8) !u4 {
    return switch (c) {
        inline '0'...'9' => @intCast(c - '0'),
        inline 'a'...'f' => @intCast(c - 'a' + 10),
        inline 'A'...'F' => @intCast(c - 'A' + 10),
        inline else => error.InvalidCharacter,
    };
}
