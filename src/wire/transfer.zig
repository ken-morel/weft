const std = @import("std");

const proto = @import("../domain/proto.zig");
const Weft = @import("../domain/Weft.zig");
const Remote = Weft.Remote;
const Connection = @import("../wire/Connection.zig");
const Packer = @import("../wire/Packer.zig");
const Pressor = @import("../wire/Pressor.zig");
const DeploymentState = @import("DeploymentState.zig");

pub const Status = struct {
    total: u64,
    sent: u64,
    file_total: u64,
    file_sent: u64,
    bytes_sent: u64,
};

pub fn pull(gpa: std.mem.Allocator, io: std.Io, conn: *Connection, dest: []const u8, status: ?*Status) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dest, .{});
    defer dir.close(io);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var packer: Packer = .unpacker(dir);
    defer packer.deinit(io);
    const pressor_buffer = try alloc.alloc(u8, Pressor.buffer_size);
    var pressor: Pressor = .init(pressor_buffer);
    const decompress_buffer = try alloc.alloc(u8, Pressor.chunk_size);

    const conn_buffer = try alloc.alloc(u8, Connection.max_packet_size);

    while (true) {
        const data = try conn.recv_buf(conn_buffer);
        if (data.len < 5 or !std.mem.eql(u8, data[0..4], "pack"))
            return error.ExpectedPackHeader;

        switch (data[4]) {
            proto.header => if (status) |s| {
                const total_files = std.mem.readInt(u64, data[5..], .little);
                s.file_total += total_files;
            },
            proto.file => {
                const size = std.mem.readInt(u64, data[5..13], .little);
                try packer.put(io, .{ .file = data[13..] });
                if (status) |s| {
                    s.file_total = size;
                    s.file_sent = 0;
                    s.sent += 1;
                }
            },
            proto.folder => try packer.put(io, .{ .folder = data[5..] }),
            proto.data => {
                const bytes = data[5..];
                if (status) |s| {
                    s.file_sent += bytes.len;
                    s.bytes_sent += bytes.len;
                }
                try packer.put(io, .{ .data = bytes });
            },
            proto.compressed_data => {
                const compressed = data[5..];
                var input: std.Io.Reader = .fixed(compressed);
                var output: std.Io.Writer = .fixed(decompress_buffer);
                try pressor.decompress(&input, &output);
                const bytes = output.buffered();
                try packer.put(io, .{ .data = bytes });
                if (status) |s| {
                    s.file_sent += bytes.len;
                    s.bytes_sent += bytes.len;
                }
            },
            proto.end => break,
            else => return error.InvalidPack,
        }
    }
}
pub fn push(gpa: std.mem.Allocator, io: std.Io, conn: *Connection, source: []const u8, compress: bool, status: ?*Status) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const alloc = arena.allocator();
    const read_buffer = try alloc.alloc(u8, Connection.max_packet_size - 20);
    const send_buffer = try alloc.alloc(u8, Connection.max_packet_size);
    const compressed_buffer = if (compress)
        try alloc.alloc(u8, Pressor.chunk_size)
    else
        &.{};

    //DEINIT: by packer
    const dir = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });

    const total_files: u64 = total_files: {
        var count_walker = try dir.walk(gpa);
        defer count_walker.deinit();
        var count: u32 = 0;
        while (try count_walker.next(io)) |entry|
            if (entry.kind == .file) {
                count += 1;
            };
        break :total_files count;
    };
    if (status) |s|
        s.total += total_files;

    var packer: Packer = try .packer_take(
        gpa,
        dir,
    );
    defer packer.deinit(io);
    var pressor: Pressor = .init(try alloc.alloc(u8, Pressor.buffer_size));

    //NOTE: using read_buffer
    const header = try std.fmt.bufPrint(send_buffer, "pack{c}{s}", .{
        proto.header,
        std.mem.writeInt(u64, read_buffer, total_files, .little),
    });
    try conn.send(header);
    while (try packer.get(io, read_buffer)) |pack| switch (pack) {
        .file => |path| {
            if (status) |s| {
                const fsize = fsize: {
                    const f = try dir.openFile(io, path, .{ .mode = .read_only });
                    defer f.close(io);
                    break :fsize try f.length();
                };
                s.sent += 1;
                s.file_total = fsize;
                s.file_sent = 0;
            }
            try conn.send(
                try std.fmt.bufPrint(send_buffer, "pack{c}{s}", .{ proto.file, path }),
            );
        },
        .folder => |path| try conn.send(
            try std.fmt.bufPrint(send_buffer, "pack{c}{s}", .{ proto.folder, path }),
        ),

        .data => |bytes| {
            var reader: std.Io.Reader = .fixed(bytes);
            var writer: std.Io.Writer = .fixed(compressed_buffer);
            const data, const compressed = if (compress) blk: {
                if (pressor.compress(&reader, &writer)) |_| {
                    break :blk .{ writer.buffered(), true };
                } else |err| {
                    if (err != error.WriteFailed)
                        return err;
                    break :blk .{ bytes, false };
                }
            } else .{ bytes, false };

            try conn.send(
                try std.fmt.bufPrint(
                    send_buffer,
                    "pack{c}{s}",
                    .{
                        if (compressed)
                            proto.compressed_data
                        else
                            proto.data,
                        data,
                    },
                ),
            );
        },
    };
    try conn.send_object(send_buffer, proto.artifact.push.Req, .end);

    const reply = try conn.recv_object_buf(send_buffer, anyerror!proto.artifact.push.Res);
    if (reply) |_| {} else |err| return err;
}
