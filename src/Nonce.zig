base: u128,
counter: u64,

pub fn init(base: u128) @This() {
    return .{
        .base = base,
        .counter = 0,
    };
}
pub fn zero() @This() {
    return .{
        .base = 0,
        .counter = 0,
    };
}

pub fn random(io: std.Io) !@This() {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&seed);
    var chacha = std.Random.DefaultCsprng.init(seed);
    const base = chacha.random().int(u128);
    return init(base);
}
pub fn inc(self: *@This()) void {
    self.counter += 1;
}
pub fn write(self: @This(), out: *std.Io.Writer) !void {
    try out.writeInt(u128, self.base, .little);
    try out.writeInt(u64, self.counter, .little);
}
pub fn read(in: *std.Io.Reader) !@This() {
    var buff: [24]u8 = undefined;
    try in.readSliceAll(&buff);

    return from_bytes(&buff);
}
pub fn to_bytes(self: @This()) [24]u8 {
    var n: [24]u8 = undefined;
    std.mem.writeInt(u128, n[0..16], self.base, .little);
    std.mem.writeInt(u64, n[16..], self.counter, .little);
    return n;
}
pub fn from_bytes(bytes: []u8) !@This() {
    if (bytes.len != 24)
        return error.InvalidSize;
    return .{
        .base = std.mem.readVarInt(u128, bytes[0..16], .little),
        .counter = std.mem.readVarInt(u64, bytes[16..], .little),
    };
}

const std = @import("std");
