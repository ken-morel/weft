const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const proto = @import("../domain/proto.zig");
const zoto = @import("../util/zoto.zig");
const Crypt = @import("Crypt.zig");
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

pub fn init(io: std.Io, secret: *const [32]u8, reader: *std.Io.Reader, writer: *std.Io.Writer) !@This() {
    try writer.writeAll("weft");
    try writer.writeInt(u64, proto.hash, .little);
    try writer.flush();

    var buff: [12]u8 = undefined;
    try reader.readSliceAll(&buff);
    const other_hash = std.mem.readInt(u64, buff[4..], .little);

    if (!std.mem.eql(u8, buff[0..4], "weft"))
        return error.InvalidProtocol
    else if (other_hash != proto.hash)
        return error.SchemaMismatch;

    const out_nonce = try Nonce.random(io);
    try out_nonce.write(writer);
    try writer.flush();
    const in_nonce = try Nonce.read(reader);

    return .{
        .reader = reader,
        .writer = writer,
        .write_crypt = .init(secret, out_nonce),
        .read_crypt = .init(secret, in_nonce),
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
