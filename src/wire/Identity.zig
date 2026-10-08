const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub const seed_length = Ed25519.KeyPair.seed_length;
pub const public_length = Ed25519.PublicKey.encoded_length;
pub const signature_length = Ed25519.Signature.encoded_length;

const ClientInstall = @import("../client/ClientInstall.zig");
const read_only_user_permissions = ClientInstall.read_only_user_permissions;

seed: [seed_length]u8,
key_pair: Ed25519.KeyPair,

pub fn from_seed(seed: [seed_length]u8) !@This() {
    const key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    return .{
        .seed = seed,
        .key_pair = key_pair,
    };
}

pub fn generate(io: std.Io) !@This() {
    var seed: [seed_length]u8 = undefined;
    try io.randomSecure(&seed);
    return from_seed(seed);
}

pub fn public_key(self: @This()) [public_length]u8 {
    return self.key_pair.public_key.toBytes();
}

pub fn sign(self: @This(), msg: []const u8) !Ed25519.Signature {
    return self.key_pair.sign(msg, null);
}

pub fn verify(pubkey_bytes: [public_length]u8, msg: []const u8, sig_bytes: [signature_length]u8) !void {
    const pk = try Ed25519.PublicKey.fromBytes(pubkey_bytes);
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    return sig.verify(msg, pk);
}

pub fn read(io: std.Io, dir: std.Io.Dir, filename: []const u8) !@This() {
    var file = try dir.openFile(io, filename, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if ((stat.permissions.toMode() & 0o777) != read_only_user_permissions.toMode())
        return error.InsecurePermissions
    else if (stat.size != seed_length)
        return error.InvalidKeyFile;

    var seed: [seed_length]u8 = undefined;
    _ = try file.readPositionalAll(io, &seed, 0);
    return from_seed(seed);
}

pub fn create(io: std.Io, dir: std.Io.Dir, filename: []const u8) !@This() {
    const identity = try generate(io);
    var file = try dir.createFile(io, filename, .{
        .exclusive = true,
        .permissions = read_only_user_permissions,
    });
    defer file.close(io);

    try file.writePositionalAll(io, &identity.seed, 0);
    std.log.warn("New keys generated in {s}", .{filename});
    return identity;
}

pub fn ensure(io: std.Io, dir: std.Io.Dir, filename: []const u8) !@This() {
    return read(io, dir, filename) catch |err|
        if (err == error.FileNotFound)
            create(io, dir, filename)
        else
            err;
}
