const std = @import("std");
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const zoto = @import("zoto.zig");
const Pipeline = @import("Pipeline.zig");
const Nonce = @import("Nonce.zig");

const packet_size = std.math.maxInt(u16);

const _ = @import("connection_test.zig");

reader: *std.Io.Reader,
writer: *std.Io.Writer,

token: []u8,

out_nonce: Nonce,
in_nonce: Nonce,

// most of the connection's lifetime is reading or writing from these using
// the network connection
read_buf: []u8,
write_buf: []u8,

// used only in a fraction of second to decrypt/encrypt data
read_cyph_buf: []u8,
write_cyph_buf: []u8,

pub const ServiceId = struct {
    workspace: []const u8,
    service: []const u8,
};
pub const DeploymentId = struct {
    service: ServiceId,
    deployment: u64,
};
pub const TaskId = struct {
    deployment: DeploymentId,
    pipeline: []const u8,
};
pub const ArtifactId = struct {
    task: TaskId,
    neg_idx: u8,
};

pub const Message = union(enum) {
    request: enum(u8) {
        artifact_push,
        artifact_pull,

        task_status,
        task_abort,

        task_create,

        logs_snapshot,
        logs_stream,

        workspace_sync,
    },

    artifact: ArtifactId,

    task: TaskId,

    pipeline: Pipeline,

    log: TaskId,
    log_stream: TaskId,

    file: struct {
        path: []const u8,
        size: u64,
    },

    bytes: []const u8,

    end: void,

    ok: void,
    err: anyerror,
};

/// The interface for the connection. Handles encryption
pub fn init(alloc: std.mem.Allocator, io: std.Io, secret: *[32]u8, reader: *std.Io.Reader, writer: *std.Io.Writer) !@This() {
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

    const token = try alloc.dupe(u8, secret);
    errdefer alloc.free(token); // unreachable for now

    return .{
        .reader = reader,
        .writer = writer,
        .out_nonce = out_nonce,
        .in_nonce = in_nonce,

        .read_buf = read_buf,
        .write_buf = write_buf,
        .read_cyph_buf = read_cyph_buf,
        .write_cyph_buf = write_cyph_buf,
        .token = token,
    };
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    alloc.free(self.read_buf);
    alloc.free(self.write_buf);
    alloc.free(self.write_cyph_buf);
    alloc.free(self.read_cyph_buf);

    alloc.free(self.token);
}

pub fn send(self: *@This(), msg: Message) !void {
    const data = try zoto.serialize(self.msg_buf, msg);
    try self.write(data);
}
pub fn recv(self: *@This(), arena: *std.heap.ArenaAllocator) !Message {
    var alloc = arena.allocator();
    const data = try self.read(self.msg_buf);

    if (data.len == 0)
        return error.EmptyMessage;

    const owned = try alloc.dupe(u8, data);
    errdefer alloc.free(owned);
    return zoto.deserialize(alloc, owned, Message);
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
    std.mem.writeInt(u16, &len, @as(u16, @intCast(data.len)), .big);

    try self.writer.writeAll(&len);
    try self.writer.writeAll(self.write_cyph_buf[0..data.len]);
    try self.writer.writeAll(&tag);
    try self.writer.flush();

    self.out_nonce.inc();
}
pub fn read(self: *@This(), buf: []u8) ![]u8 {
    if (buf.len < packet_size)
        return error.BufferTooSmall;

    var tag: [16]u8 = undefined;
    var len: [2]u8 = undefined;

    try self.reader.readSliceAll(&len);
    const size = std.mem.readInt(u16, len, .big);

    if (size > buf.len or size > packet_size)
        return error.FrameTooLarge;

    try self.reader.readSliceAll(self.read_cyph_buf[0..size]);

    try self.reader.readSliceAll(&tag);

    var nonce: [24]u8 = undefined;
    self.in_nonce.write(&nonce);

    try XChaCha20Poly1305.decrypt(
        buf[0..size],
        self.read_cyph_buf[0..size],
        tag,
        &.{},
        &nonce,
        &self.token,
    );
    self.in_nonce.inc();
    return buf[0..size];
}
