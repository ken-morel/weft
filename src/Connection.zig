const std = @import("std");
const zoto = @import("zoto.zig");
const Nonce = @import("Nonce.zig");
const Deployment = @import("Deployment.zig");
const Crypt = @import("Crypt.zig");

pub const max_packet_size = std.math.maxInt(u16);

reader: *std.Io.Reader,
writer: *std.Io.Writer,

write_crypt: Crypt,
read_crypt: Crypt,

pub fn init(io: std.Io, secret: *[32]u8, reader: *std.Io.Reader, writer: *std.Io.Writer) !@This() {
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
