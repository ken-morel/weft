const std = @import("std");

const UUIDv7 = @This();

bytes: [16]u8,

pub fn now(io: std.Io) !UUIDv7 {
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

pub fn timestamp(self: UUIDv7) u48 {
    return std.mem.readInt(u48, self.bytes[0..6], .big);
}

pub fn rand(self: UUIDv7) struct { u12, u62 } {
    const raw1 = std.mem.readInt(u16, self.bytes[6..8], .big);
    const raw2 = std.mem.readInt(u64, self.bytes[8..16], .big);
    return .{ @intCast(raw1 & 0x0fff), @intCast(raw2 & 0x3fff_ffff_ffff_ffff) };
}

pub fn format(
    self: UUIDv7,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    const full_fmt = ("{" ++ fmt ++ "}-") ** 5;
    try writer.print(full_fmt[0 .. full_fmt.len - 1], .{
        self.bytes[0..4],
        self.bytes[4..6],
        self.bytes[6..8],
        self.bytes[8..10],
        self.bytes[10..16],
    });
}

pub fn to_string(self: UUIDv7) [36]u8 {
    var buf: [36]u8 = undefined;
    std.fmt.bufPrint(&buf, "{}", .{self}) catch unreachable;
    return buf;
}

pub fn parse(input: []const u8) !UUIDv7 {
    if (input.len != 36)
        return error.InvalidLength;

    if (input[8] != '-' or input[13] != '-' or input[18] != '-' or input[23] != '-')
        return error.InvalidCharacter;

    var self: UUIDv7 = undefined;
    var out_idx: usize = 0;
    var in_idx: usize = 0;

    while (in_idx < input.len) {
        if (input[in_idx] == '-') {
            in_idx += 1;
            continue;
        }

        const high_nibble = try parseHex(input[in_idx]);
        const low_nibble = try parseHex(input[in_idx + 1]);

        self.bytes[out_idx] = (high_nibble << 4) | low_nibble;
        out_idx += 1;
        in_idx += 2;
    }

    return self;
}

inline fn parseHex(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => error.InvalidCharacter,
    };
}
