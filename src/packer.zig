const std = @import("std");

pub const Packer = struct {
    root: std.Io.Dir,
    walker: std.Io.Dir.Walker,
    handle: ?std.Io.File = null,

    pub fn init(alloc: std.mem.Allocator, dir: std.Io.Dir) !@This() {
        const self = try alloc.create(@This());
        self.root = dir;
        self.walker = try dir.walk(alloc);
        self.handle = null;
        return .{
            .root = dir,
            .walker = try dir.walk(alloc),
        };
    }

    pub fn deinit(self: @This(), io: std.Io) void {
        self.root.close(io);
        self.walker.deinit();
        if (self.handle) |file|
            file.close(io);
    }

    pub fn next(self: *@This(), io: std.Io, buffer: []u8) !?union(enum) { file: []const u8, folder: []const u8, data: []const u8 } {
        next: while (true) {
            if (self.handle) |file_handle| {
                const read = file_handle.readStreaming(
                    io,
                    &.{buffer},
                ) catch |err|
                    if (err == error.EndOfStream)
                        0
                    else
                        return err;
                if (read > 0)
                    return .{ .data = read };
                file_handle.close(io);
                self.handle = null;
                continue :next;
            } else {
                const entry = try self.walker.next(io) orelse return null;

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
};

pub const Unpacker = struct {
    root: std.Io.Dir,
    handle: ?std.Io.File = null,

    pub fn init(dir: std.Io.Dir) !@This() {
        return .{
            .root = dir,
        };
    }

    pub fn deinit(self: *@This(), io: std.Io) void {
        if (self.handle) |f|
            f.close(io);
        self.root.close(io);
    }

    pub fn folder(self: *@This(), io: std.Io, path: []const u8) !void {
        try self.root.createDirPath(io, path);
    }

    pub fn file(self: *@This(), io: std.Io, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent_dir|
            try self.root.createDirPath(io, parent_dir);
        if (self.handle) |h|
            h.close(io);
        self.handle = try self.root.createFile(io, path, .{ .truncate = true });
    }

    pub fn chunk(self: *@This(), io: std.Io, bytes: []const u8) !void {
        const file_handle = self.handle orelse return error.FileNotOpened;

        try file_handle.writeStreamingAll(io, bytes);
    }
};
