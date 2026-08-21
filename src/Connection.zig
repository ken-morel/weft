const std = @import("std");
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const zoto = @import("zoto.zig");
const Weft = @import("Weft.zig");
const Nonce = @import("Nonce.zig");
const Deployment = @import("Deployment.zig");
const UUIDv7 = @import("UUIDv7.zig");
const ids = @import("ids.zig");
const Task = @import("Task.zig");

pub const packet_size = std.math.maxInt(u16);

reader: *std.Io.Reader,
writer: *std.Io.Writer,

token: [32]u8,

out_nonce: Nonce,
in_nonce: Nonce,

read_buf: []u8,
write_buf: []u8,

read_cyph_buf: []u8,
write_cyph_buf: []u8,

pub const Message = union(enum) {
    request: enum(u8) {
        artifact_push,
        artifact_pull,

        task_status,
        task_abort,

        task_spawn,

        logs_snapshot,
        logs_stream,

        workspace_sync,
    },

    artifact_id: ids.ArtifactId,

    task_id: ids.TaskId,
    task_spec: Task.Spec,

    file: []const u8,
    folder: []const u8,

    data: []const u8,

    ok: void,
    bool: bool,
    err: anyerror,
    end: void,
};

pub fn init(alloc: std.mem.Allocator, io: std.Io, secret: []const u8, reader: *std.Io.Reader, writer: *std.Io.Writer) !@This() {
    const out_nonce = try Nonce.random(io);
    try out_nonce.write(writer);
    try writer.flush();

    const in_nonce = try Nonce.read(reader);

    const read_buf = try alloc.alloc(u8, packet_size);
    errdefer alloc.free(read_buf);

    const write_buf = try alloc.alloc(u8, packet_size);
    errdefer alloc.free(write_buf);

    const read_cyph_buf = try alloc.alloc(u8, packet_size);
    errdefer alloc.free(read_cyph_buf);

    const write_cyph_buf = try alloc.alloc(u8, packet_size);
    errdefer alloc.free(write_cyph_buf);

    if (secret.len != 32)
        return error.InvalidSecret;
    var stack_secret: [32]u8 = undefined;
    std.mem.copyForwards(u8, &stack_secret, secret);

    return .{
        .reader = reader,
        .writer = writer,
        .out_nonce = out_nonce,
        .in_nonce = in_nonce,

        .read_buf = read_buf,
        .write_buf = write_buf,
        .read_cyph_buf = read_cyph_buf,
        .write_cyph_buf = write_cyph_buf,
        .token = stack_secret,
    };
}

pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
    alloc.free(self.read_buf);
    alloc.free(self.write_buf);
    alloc.free(self.write_cyph_buf);
    alloc.free(self.read_cyph_buf);
}

pub fn send(self: *@This(), msg: Message) !void {
    var ptr = self.write_buf;
    try zoto.serializeValue(&ptr, msg);
    try self.write(self.write_buf[0 .. self.write_buf.len - ptr.len]);
}
pub fn recv(self: *@This(), arena: *std.heap.ArenaAllocator) !Message {
    const data = try self.read(self.read_buf);

    if (data.len == 0)
        return error.EmptyMessage;

    const owned = try arena.allocator().dupe(u8, data);
    var const_slice: []const u8 = owned;
    return zoto.deserializeValue(arena, &const_slice, Message);
}

pub fn write(self: *@This(), data: []const u8) !void {
    if (data.len == 0)
        return error.EmptyMessage;
    if (data.len > packet_size)
        return error.MessageToLarge;

    const nonce = self.out_nonce.to_bytes();
    var tag: [16]u8 = undefined;

    XChaCha20Poly1305.encrypt(
        self.write_cyph_buf[0..data.len],
        &tag,
        data,
        &.{},
        nonce,
        self.token,
    );
    var len: [2]u8 = undefined;
    std.mem.writeInt(u16, &len, @as(u16, @intCast(data.len)), .little);

    try self.writer.writeAll(&len);
    try self.writer.writeAll(self.write_cyph_buf[0..data.len]);
    try self.writer.writeAll(&tag);
    try self.writer.flush();

    self.out_nonce.inc();
}
pub fn read(self: *@This(), buf: []u8) ![]u8 {
    // if (buf.len < packet_size)
    //     return error.BufferTooSmall;

    var tag: [16]u8 = undefined;
    var len: [2]u8 = undefined;

    try self.reader.readSliceAll(&len);
    const size = std.mem.readInt(u16, &len, .little);

    if (size > buf.len or size > packet_size)
        return error.FrameTooLarge;

    try self.reader.readSliceAll(self.read_cyph_buf[0..size]);

    try self.reader.readSliceAll(&tag);

    const nonce = self.in_nonce.to_bytes();

    try XChaCha20Poly1305.decrypt(
        buf[0..size],
        self.read_cyph_buf[0..size],
        tag,
        &.{},
        nonce,
        self.token,
    );
    self.in_nonce.inc();
    return buf[0..size];
}
