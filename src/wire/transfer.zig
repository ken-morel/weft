const std = @import("std");

const proto = @import("../domain/proto.zig");
const Weft = @import("../domain/Weft.zig");
const Remote = Weft.Remote;
const Connection = @import("../wire/Connection.zig");
const Packer = @import("../wire/Packer.zig");
const Pressor = @import("../wire/Pressor.zig");

pub const Status = struct {
    total: u64 = 0,
    sent: u64 = 0,
    file_total: u64 = 0,
    file_sent: u64 = 0,
    bytes_sent: u64 = 0,
    done: bool = false,
    err: ?anyerror = null,
    pub const init: @This() = .{};
};

pub fn pull(gpa: std.mem.Allocator, io: std.Io, conn: *Connection, dest: []const u8, decompress: bool, status: ?*Status) !void {
    _pull(gpa, io, conn, dest, decompress, status) catch |err| {
        if (status) |s| {
            s.err = err;
            s.done = true;
        }
        return err;
    };
    if (status) |s|
        s.done = true;
}

pub fn _pull(gpa: std.mem.Allocator, io: std.Io, conn: *Connection, dest: []const u8, decompress: bool, status: ?*Status) !void {
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

    try conn.send(
        try std.fmt.bufPrint(
            conn_buffer,
            "pack{c}{s}",
            .{
                @backingInt(proto.Pack.pull),
                std.mem.asBytes(&proto.Pack.Pull{
                    .allow_compress = decompress,
                }),
            },
        ),
    );
    const header_bytes = try conn.recv_buf(conn_buffer);
    if (header_bytes.len != 4 + 1 + @sizeOf(proto.Pack.Push) or
        !std.mem.eql(u8, header_bytes[0..4], "pack") or
        header_bytes[4] != @backingInt(proto.Pack.push))
        return error.InvalidHeader;
    var header: proto.Pack.Push = undefined;
    @memcpy(std.mem.asBytes(&header), header_bytes[5..]);
    if (status) |s|
        s.total += header.total_files;

    while (true) {
        const data = try conn.recv_buf(conn_buffer);
        if (data.len < 5 or !std.mem.eql(u8, data[0..4], "pack"))
            return error.ExpectedPackHeader;

        switch (data[4]) {
            proto.header => if (status) |s| {
                const total_files = std.mem.readInt(u64, data[5..13], .little);
                s.total += total_files;
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
    _push(gpa, io, conn, source, compress, status) catch |err| {
        if (status) |s| {
            s.err = err;
            s.done = true;
        }
        return err;
    };
    if (status) |s|
        s.done = true;
}

pub fn _push(gpa: std.mem.Allocator, io: std.Io, conn: *Connection, source: []const u8, allow_compress: bool, status: ?*Status) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const read_buffer = try alloc.alloc(u8, Connection.max_packet_size - 20);
    const send_buffer = try alloc.alloc(u8, Connection.max_packet_size);

    const dir = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
    defer dir.close(io);

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
    if (status) |s| {
        s.total += total_files;
        s.done = false;
    }

    var packer: Packer = try Packer.packer_take(
        gpa,
        dir,
    );
    defer packer.deinit(io);

    try conn.send(
        try std.fmt.bufPrint(
            send_buffer,
            "pack{c}{s}",
            .{
                @backingInt(proto.Pack.push),
                std.mem.asBytes(&proto.Pack.Push{
                    .total_files = total_files,
                }),
            },
        ),
    );
    const header_bytes = try conn.recv_buf(read_buffer);
    if (header_bytes.len != 4 + 1 + @sizeOf(proto.Pack.Pull) or
        !std.mem.eql(u8, header_bytes[0..4], "pack") or
        header_bytes[4] != @backingInt(proto.Pack.pull))
        return error.InvalidHeader;

    var header: proto.Pack.Pull = undefined;
    @memcpy(std.mem.asBytes(&header), header_bytes[5..]);

    const compress = allow_compress and header.allow_compress;

    var pressor: Pressor = if (compress)
        .init(try alloc.alloc(u8, Pressor.buffer_size))
    else
        undefined;

    const compressed_buffer: []u8 = if (compress)
        try alloc.alloc(u8, Pressor.chunk_size)
    else
        undefined;

    while (try packer.get(io, read_buffer)) |pack| switch (pack) {
        .file => |path| {
            const fsize = fsize: {
                const f = try dir.openFile(io, path, .{ .mode = .read_only });
                defer f.close(io);
                break :fsize try f.length(io);
            };
            if (status) |s| {
                s.sent += 1;
                s.file_total = fsize;
                s.file_sent = 0;
            }
            var fsize_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &fsize_buf, fsize, .little);
            try conn.send(
                try std.fmt.bufPrint(send_buffer, "pack{c}{s}{s}", .{ proto.file, &fsize_buf, path }),
            );
        },
        .folder => |path| try conn.send(
            try std.fmt.bufPrint(send_buffer, "pack{c}{s}", .{ proto.folder, path }),
        ),
        .data => |bytes| {
            var reader: std.Io.Reader = .fixed(bytes);
            var writer: std.Io.Writer = .fixed(compressed_buffer);
            const data, const is_compressed = if (compress) blk: {
                if (pressor.compress(&reader, &writer)) |_| {
                    if (writer.buffered().len < bytes.len)
                        break :blk .{ writer.buffered(), true }
                    else
                        break :blk .{ bytes, false };
                } else |err| {
                    if (err != error.WriteFailed)
                        return err;
                    break :blk .{ bytes, false };
                }
            } else .{ bytes, false };

            if (status) |s| {
                s.file_sent += bytes.len;
                s.bytes_sent += data.len;
            }

            try conn.send(
                try std.fmt.bufPrint(
                    send_buffer,
                    "pack{c}{s}",
                    .{
                        if (is_compressed)
                            proto.compressed_data
                        else
                            proto.data,
                        data,
                    },
                ),
            );
        },
    };
    try conn.send(try std.fmt.bufPrint(send_buffer, "pack{c}", .{proto.end}));
}
