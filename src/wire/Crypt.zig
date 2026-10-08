const std = @import("std");
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

pub const Identity = @import("Identity.zig");
pub const Nonce = @import("Nonce.zig");

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
pub const magick: [4]u8 = "weft".*;

pub const ClientHello = extern struct {
    magic: [4]u8 = magick,
    proto_hash: u64,
    client_public: [Identity.public_length]u8,
    client_temp_pub: [32]u8,
    client_nonce: [24]u8,
};

pub const ServerChallenge = extern struct {
    pub const Status = enum(u8) {
        ok = 0,
        unauthorized = 1,
        proto_mismatch = 2,
    };

    status: Status,
    challenge: [32]u8,
    server_temp_pub: [32]u8,
    server_nonce: [24]u8,
};

pub const ClientAuth = extern struct {
    signature: [Identity.signature_length]u8,
};

pub fn make_sign_data(challenge: *const [32]u8, server_temp_pub: *const [32]u8) [64]u8 {
    var out: [64]u8 = undefined;
    @memcpy(out[0..32], challenge);
    @memcpy(out[32..64], server_temp_pub);
    return out;
}
