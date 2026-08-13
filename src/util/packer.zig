const std = @import("std");
const flate = std.compress.flate;

const window_size = 64 << 10;
const max_compressed_size = std.math.maxInt(u16) - 20;
// Strip possible deflate overhead (above 0.03%)
const max_uncompressed_size = max_compressed_size - (max_compressed_size / 1000);

pub const Packer = struct {
    input: []u8,
    output: []u8,
    buffer: []u8,
    root: std.Io.Dir,
    walker: std.Io.Dir.Walker,
    handle: ?std.Io.File = null,

    pub fn init(alloc: std.mem.Allocator, dir: std.Io.Dir) !*@This() {
        const self = try alloc.create(@This());
        self.output = try alloc.alloc(u8, max_compressed_size);
        self.input = try alloc.alloc(u8, max_uncompressed_size);
        self.buffer = try alloc.alloc(u8, window_size);
        self.writer = .fixed(self.output);
        self.root = dir;
        self.walker = try dir.walk(alloc);
        self.handle = null;
        return self;
    }

    pub fn destroy(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
        alloc.free(self.input);
        alloc.free(self.output);
        alloc.free(self.buffer);
        self.root.close(io);
        self.walker.deinit();
        if (self.handle) |file|
            file.close(io);

        alloc.destroy(self);
    }

    pub fn next(self: *@This(), io: std.Io) !?union(enum) { file: []const u8, folder: []const u8, data: []const u8 } {
        next: while (true) {
            if (self.handle) |file_handle| {
                const bytes_read = try file_handle.readStreaming(io, self.input);
                if (bytes_read == 0) {
                    file_handle.close(io);
                    self.handle = null;
                    continue :next;
                }

                var writer: std.Io.Writer = .fixed(self.output);

                var compressor = try flate.Compress.init(
                    &writer,
                    self.buffer,
                    .zlib,
                    flate.Compress.Options.level_5,
                );

                try compressor.writer.writeAll(self.input[0..bytes_read]);
                try compressor.bit_writer.byteAlignBlocks();

                return writer.buffered();
            } else {
                const entry = (try self.walker.next(io)).?;

                switch (entry.kind) {
                    .directory => return .{ .folder = entry.path },
                    .file => {
                        self.handle = try entry.dir.openFile(io, entry.basename, .{});
                        return .{ .file = entry.path };
                    },
                    else => continue :next,
                }
            }
        }
    }

    pub fn close(self: *@This(), io: std.Io) void {
        if (self.handle) |file| {
            file.close(io);
            self.handle = null;
        }
    }
};

pub const Unpacker = struct {
    input: []u8,
    output: []u8,
    buffer: []u8,
    root: std.Io.Dir,

    handle: ?std.Io.File,

    pub fn init(alloc: std.mem.Allocator, dir: std.Io.Dir) !*@This() {
        const self = try alloc.create(@This());
        self.output = try alloc.alloc(u8, max_uncompressed_size);
        self.input = try alloc.alloc(u8, max_compressed_size);
        self.buffer = try alloc.alloc(u8, window_size);
        self.root = dir;
        self.handle = null;
        return self;
    }

    pub fn destroy(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
        alloc.free(self.input);
        alloc.free(self.output);
        alloc.free(self.buffer);
        self.root.close(io);
        if (self.handle) |f|
            f.close(io);
        alloc.destroy(self);
    }

    pub fn folder(self: *@This(), io: std.Io, path: []const u8) !void {
        try self.root.makePath(io, path);
    }

    pub fn file(self: *@This(), io: std.Io, path: []const u8) void {
        if (std.fs.path.dirname(path)) |parent_dir|
            try self.root.makePath(io, parent_dir);
        if (self.handle) |h|
            h.close(io);
        self.handle = try self.root.createFile(io, path, .{ .truncate = true });
    }

    pub fn chunk(self: *@This(), io: std.Io, compressed_bytes: []const u8) !void {
        const file_handle = self.handle orelse return error.FileNotOpened;

        var reader: std.Io.Reader = .fixed(compressed_bytes);

        var decompressor: flate.Decompress = try .init(
            &reader,
            self.buffer,
            .zlib,
        );

        const bytes_decompressed = try decompressor.reader.readAll(self.output);

        try file_handle.writeAll(io, self.output[0..bytes_decompressed]);
    }
};
