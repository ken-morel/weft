const std = @import("std");
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Nonce = @import("Nonce.zig");

secret: [32]u8,
nonce: Nonce,

pub const packet_size = std.math.maxInt(u16);

pub fn init(secret: *const [32]u8, nonce: Nonce) @This() {
    return .{
        .secret = secret.*,
        .nonce = nonce,
    };
}

pub fn encrypt(self: *@This(), tag: *[16]u8, data: []u8) !void {
    if (data.len == 0)
        return error.EmptyMessage;
    if (data.len > packet_size)
        return error.MessageToLarge;
    const nonce = self.nonce.to_bytes();
    self.inc();
    XChaCha20Poly1305.encrypt(
        data,
        tag,
        data,
        &.{},
        nonce,
        self.secret,
    );
}
pub fn decrypt(self: *@This(), tag: *[16]u8, data: []u8) !void {
    if (data.len == 0)
        return error.EmptyMessage;
    if (data.len > packet_size)
        return error.MessageToLarge;
    const nonce = self.nonce.to_bytes();
    self.inc();

    try XChaCha20Poly1305.decrypt(
        data,
        data,
        tag.*,
        &.{},
        nonce,
        self.secret,
    );
}

pub fn inc(self: *@This()) void {
    self.nonce.inc();
}
pub fn dec(self: *@This()) void {
    self.nonce.dec();
}
