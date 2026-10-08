const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;

const Deployment = @import("../client/Deployment.zig");
const proto = @import("../domain/proto.zig");
const zoto = @import("../util/zoto.zig");
const Crypt = @import("Crypt.zig");
const Handshake = @import("Handshake.zig");
const Identity = @import("Identity.zig");
const Nonce = @import("Nonce.zig");

pub const max_packet_size = std.math.maxInt(u16);

const ZotoOptions: zoto.Options = .{
    .hash = true,
    .header = false,
};

reader: *std.Io.Reader,
writer: *std.Io.Writer,

write_crypt: Crypt,
read_crypt: Crypt,

pub fn init_client(io: std.Io, identity: Identity, reader: *std.Io.Reader, writer: *std.Io.Writer) !@This() {
    const temp_dh = std.crypto.dh.X25519.KeyPair.generate(io);
    const out_nonce = try Nonce.random(io);

    const hello: Crypt.ClientHello = .{
        .proto_hash = proto.hash,
        .client_public = identity.public_key(),
        .client_temp_pub = temp_dh.public_key,
        .client_nonce = out_nonce.to_bytes(),
    };
    try writer.writeAll(std.mem.asBytes(&hello));
    try writer.flush();

    var challenge_msg: Crypt.ServerChallenge = undefined;
    try reader.readSliceAll(std.mem.asBytes(&challenge_msg));
    switch (challenge_msg.status) {
        .ok => {},
        .unauthorized => return error.ClientUnauthorized,
        .proto_mismatch => return error.ProtocolMismatch,
    }

    const sign_data = Crypt.make_sign_data(&challenge_msg.challenge, &challenge_msg.server_temp_pub);
    const sig = try identity.sign(&sign_data);

    const auth: Crypt.ClientAuth = .{
        .signature = sig.toBytes(),
    };
    try writer.writeAll(std.mem.asBytes(&auth));
    try writer.flush();

    const shared_secret = try std.crypto.dh.X25519.scalarmult(
        temp_dh.secret_key,
        challenge_msg.server_temp_pub,
    );

    var in_nonce_bytes = challenge_msg.server_nonce;
    const in_nonce = try Nonce.from_bytes(&in_nonce_bytes);

    return .{
        .reader = reader,
        .writer = writer,
        .write_crypt = .init(&shared_secret, out_nonce),
        .read_crypt = .init(&shared_secret, in_nonce),
    };
}

pub fn send(self: *@This(), buffer: []u8) !void {
    if (buffer.len > max_packet_size)
        return error.MessageTooLarge;

    var tag: [16]u8 = undefined;

    try self.writer.writeInt(u16, @intCast(buffer.len), .little);

    try self.write_crypt.encrypt(&tag, buffer);

    try self.writer.writeAll(buffer);
    try self.writer.writeAll(&tag);
    try self.writer.flush();
}

pub fn send_object(self: *@This(), buffer: []u8, comptime T: type, data: T) !void {
    var writer: std.Io.Writer = .fixed(buffer);
    try zoto.serialize(&writer, T, data, ZotoOptions);
    try self.send(writer.buffered());
}

pub fn recv(self: *@This(), alloc: std.mem.Allocator) ![]u8 {
    var tag: [16]u8 = undefined;
    var len: [2]u8 = undefined;

    try self.reader.readSliceAll(&len);

    const size = std.mem.readInt(u16, &len, .little);

    const data = try alloc.alloc(u8, size);

    try self.reader.readSliceAll(data);
    try self.reader.readSliceAll(&tag);
    try self.read_crypt.decrypt(&tag, data[0..size]);

    return data;
}

pub fn recv_buf(self: *@This(), buf: []u8) ![]u8 {
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    return self.recv(fba.allocator()) catch |err| {
        return if (err == error.OutOfMemory)
            error.BufferTooSmall
        else
            err;
    };
}

pub fn recv_object(self: *@This(), alloc: std.mem.Allocator, comptime T: type) !T {
    var data: []const u8 = try self.recv(alloc);
    return try zoto.deserialize(alloc, &data, T, ZotoOptions);
}

pub fn recv_object_buf(self: *@This(), buf: []u8, comptime T: type) !T {
    var alloc: std.heap.FixedBufferAllocator = .init(buf);
    return self.recv_object(alloc.allocator(), T) catch |err|
        return if (err == error.OutOfMemory)
            error.BufferTooSmall
        else
            err;
}
