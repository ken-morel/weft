const std = @import("std");

const window_size = 64 << 10;
const max_compressed_size = std.math.maxInt(u16) - 20;
// Strip possible deflate overhead (above 0.03%)
const max_uncompressed_size = max_compressed_size - (max_compressed_size / 1000);

const total_alloc = window_size + max_compressed_size;
memory: []u8,
buffer: []u8,

pub fn init(alloc: std.mem.Allocator) !@This() {
    const buffer = try alloc.alloc(u8, window_size);
    const output = try alloc.alloc(u8, max_compressed_size);

    return .{
        .memory = buffer,
        .buffer = output,
    };
}
pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
    alloc.free(self.memory);
    alloc.free(self.buffer);
}

pub fn compress(self: @This(), data: []const u8) ![]u8 {
    if (data.len > max_uncompressed_size)
        return error.CompressDataTooLarge;
    var writer: std.Io.Writer = .fixed(self.buffer);
    var compressor: std.compress.flate.Compress = .init(
        &writer,
        self.memory,
        .zlib,
        .level_1,
    );
    try compressor.writer.writeAll(data);
    try compressor.finish();
    return writer.buffered();
}
pub fn decompress(self: @This(), data: []const u8) ![]u8 {
    if (data.len > max_compressed_size)
        return error.DecompressDataTooLarge;

    var reader: std.Io.Reader = .fixed(data);

    var decompressor: std.compress.flate.Decompress = .init(
        &reader,
        .zlib,
        self.memory,
    );

    var idx = 0;
    while (true) { //TODO: remove the outer while true
        const len = try decompressor.reader.readSliceShort(self.buffer[idx..]);
        if (len == 0)
            break
        else
            idx += len;
    }
    return self.buffer[0..idx];
}
