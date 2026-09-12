const std = @import("std");

const window_size = 64 << 10;
pub const max_compressed_size = std.math.maxInt(u16) - 20;

// Strip possible deflate overhead (above 0.03%)
pub const max_uncompressed_size = max_compressed_size - (max_compressed_size / 2000);

pub const buffer_size = window_size;

pub fn init(buffer: []u8) @This() {
    return .{ .buffer = buffer };
}

buffer: []u8,

pub fn compress(self: @This(), input: *std.Io.Reader, output: *std.Io.Writer) !void {
    var compressor: std.compress.flate.Compress = try .init(
        output,
        self.buffer,
        .zlib,
        .level_4,
    );
    _ = try input.streamRemaining(&compressor.writer);
    try compressor.finish();
}
pub fn decompress(self: @This(), input: *std.Io.Reader, output: *std.Io.Writer) !void {
    var decompressor: std.compress.flate.Decompress = .init(
        input,
        .zlib,
        self.buffer,
    );
    _ = try decompressor.reader.streamRemaining(output);
}
