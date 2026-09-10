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

token: [32]u8, // must be a [32]u8

out_nonce: Nonce,
in_nonce: Nonce,

read_buf: []u8,
write_buf: []u8,

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

    raw: []const u8,
    compressed: []const u8,

    ok,
    bool: bool,
    err: anyerror,
    end,
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
        .token = stack_secret,
    };
}

pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
    alloc.free(self.read_buf);
    alloc.free(self.write_buf);
}

pub fn send(self: *@This(), msg: Message) !void {
    var ptr = self.write_buf;
    try zoto.serializeValue(&ptr, msg);
    try self.write(@intCast(self.write_buf.len - ptr.len));
}
pub fn recv_dupe(self: *@This(), alloc: std.mem.Allocator) !Message {
    const len = try self.read();

    if (len == 0)
        return error.EmptyMessage;

    const owned = try alloc.dupe(u8, self.read_buf[0..len]);
    var const_slice: []const u8 = owned;
    return zoto.deserializeValue(alloc, &const_slice, Message);
}
pub fn recv_ref(self: *@This(), alloc: ?std.mem.Allocator) !Message {
    const len = try self.read();
    if (len == 0)
        return error.EmptyMessage;

    var ptr: []const u8 = self.read_buf[0..len];

    return zoto.deserializeValue(alloc, &ptr, Message);
}

fn write(self: *@This(), len: u16) !void {
    if (len == 0)
        return error.EmptyMessage;
    if (len > packet_size)
        return error.MessageToLarge;

    const nonce = self.out_nonce.to_bytes();
    var tag: [16]u8 = undefined;

    XChaCha20Poly1305.encrypt(
        self.write_buf[0..len],
        &tag,
        self.write_buf[0..len],
        &.{},
        nonce,
        self.token,
    );

    try self.writer.writeInt(u16, len, .little);
    try self.writer.writeAll(self.write_buf[0..len]);
    try self.writer.writeAll(&tag);
    try self.writer.flush();

    self.out_nonce.inc();
}
fn read(self: *@This()) !u16 {
    var tag: [16]u8 = undefined;
    var len: [2]u8 = undefined;

    try self.reader.readSliceAll(&len);
    const size = std.mem.readInt(u16, &len, .little);

    const nonce = self.in_nonce.to_bytes();
    self.in_nonce.inc();

    try self.reader.readSliceAll(self.read_buf[0..size]);
    try self.reader.readSliceAll(&tag);

    try XChaCha20Poly1305.decrypt(
        self.read_buf[0..size],
        self.read_buf[0..size],
        tag,
        &.{},
        nonce,
        self.token,
    );
    return size;
}
