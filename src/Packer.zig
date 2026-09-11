const std = @import("std");

const Pack = union(enum) {
    file: []const u8,
    folder: []const u8,
    data: []const u8,
};

root: std.Io.Dir,
walker: ?std.Io.Dir.Walker = null,
handle: ?std.Io.File = null,

pub fn packer(alloc: std.mem.Allocator, dir: std.Io.Dir) !@This() {
    const self = try alloc.create(@This());
    self.root = dir;
    self.walker = try dir.walk(alloc);
    self.handle = null;
    return .{
        .root = dir,
        .walker = try dir.walk(alloc),
    };
}
pub fn unpacker(dir: std.Io.Dir) !@This() {
    return .{
        .root = dir,
    };
}

pub fn deinit(self: @This(), io: std.Io) void {
    self.root.close(io);
    if (self.walker) |walker|
        walker.deinit();
    if (self.handle) |handle|
        handle.close(io);
}

pub fn get(self: @This(), io: std.Io, buffer: []u8) !?Pack {
    if (self.walker == null)
        return error.NotAnUnpacker;
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
pub fn put(self: @This(), io: std.Io, pack: Pack) !void {
    switch (pack) {
        .folder => |path| {
            try self.root.createDirPath(io, path);
        },
        .file => |path| {
            if (std.fs.path.dirname(path)) |parent_dir|
                try self.root.createDirPath(io, parent_dir);
            if (self.handle) |h|
                h.close(io);
            self.handle = try self.root.createFile(io, path, .{ .truncate = true });
        },
        .data => |data| {
            const file_handle = self.handle orelse return error.FileNotOpened;
            try file_handle.writeStreamingAll(io, data);
        },
    }
}
