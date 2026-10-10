const std = @import("std");

const Server = @import("../daemon/Server.zig");
const proto = @import("../domain/proto.zig");
pub const Connection = @import("../wire/Connection.zig");
const Crypt = @import("../wire/Crypt.zig");
const Handshake = @import("../wire/Handshake.zig");
const Identity = @import("../wire/Identity.zig");
const Nonce = @import("../wire/Nonce.zig");

conn: Connection,
reader: std.Io.net.Stream.Reader,
writer: std.Io.net.Stream.Writer,
buffer: []u8,
stream: std.Io.net.Stream,

fn create(gpa: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, identity: Identity) !*@This() {
    const self = try gpa.create(@This());
    errdefer gpa.destroy(self);
    const buffer = try gpa.alloc(u8, 8 << 10);
    errdefer gpa.free(buffer);

    self.stream = stream;
    self.buffer = buffer;
    self.reader = stream.reader(io, buffer[0 .. buffer.len / 2]);
    self.writer = stream.writer(io, buffer[buffer.len / 2 ..]);

    const temp_dh = std.crypto.dh.X25519.KeyPair.generate(io);
    const out_nonce = try Nonce.random(io);

    const hello: Crypt.ClientHello = .{
        .client_public = identity.public_key(),
        .client_temp_pub = temp_dh.public_key,
        .client_nonce = out_nonce.to_bytes(),
    };
    const writer = &self.writer.interface;
    const reader = &self.reader.interface;

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

    self.conn = .{
        .reader = reader,
        .writer = writer,
        .write_crypt = .init(&shared_secret, out_nonce),
        .read_crypt = .init(&shared_secret, in_nonce),
    };
    return self;
}

pub fn connect(gpa: std.mem.Allocator, io: std.Io, addr: std.Io.net.IpAddress, identity: Identity) !*@This() {
    const stream = try addr.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    errdefer stream.close(io);
    return try create(gpa, io, stream, identity);
}

pub fn destroy(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
    self.stream.close(io);
    alloc.free(self.buffer);
    alloc.destroy(self);
}
