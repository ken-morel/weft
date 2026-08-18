const std = @import("std");
const Glob = @import("Glob.zig");

const max_gitignore_size = 1 << 10;

const ignore_files = [_][]const u8{
    ".gitignore",
    ".weftignore",
    ".ignore",
};

const default_ignore = [_]Glob{
    .parse(".weft", null),
    .parse(".git", null),
    .parse(".jj", null),
};

ignore_list: std.ArrayList(Glob),
walker: std.Io.Dir.SelectiveWalker,
root: std.Io.Dir,

pub fn init(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    dir: std.Io.Dir,
) !@This() {
    var self: @This() = .{
        .ignore_list = .empty,
        .walker = try dir.walkSelectively(arena.allocator()),
        .root = dir,
    };
    try self.add_ignores(arena.allocator(), io, self.root, ".");
    return self;
}
pub fn deinit(self: *@This(), arena: *std.heap.ArenaAllocator) void {
    self.ignore_list.deinit(arena.allocator());
    self.walker.deinit();
}

const Entry = union(enum) {
    file: []const u8,
    dir: []const u8,
};

fn add_ignores(
    self: *@This(),
    alloc: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    dir_path: []const u8,
) !void {
    const stable_dir_path = try alloc.dupe(u8, dir_path);
    for (ignore_files) |ignore_file| {
        const ignore_rel_path = try std.fs.path.join(alloc, &.{ dir_path, ignore_file });
        defer alloc.free(ignore_rel_path);
        const content = root.readFileAlloc(
            io,
            ignore_rel_path,
            alloc,
            .limited(max_gitignore_size),
        ) catch |err|
            if (err == error.FileNotFound)
                continue
            else
                return err;

        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            try self.ignore_list.append(alloc, Glob.parse(line, stable_dir_path));
        }
    }
}
pub fn next(self: *@This(), arena: *std.heap.ArenaAllocator, io: std.Io) !?Entry {
    const alloc = arena.allocator();
    func: while (try self.walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (self.is_ignored(entry.path, true))
                    continue :func;
                try self.add_ignores(alloc, io, self.root, entry.path);
                try self.walker.enter(io, entry);
                return .{ .dir = entry.path };
            },
            .file => if (self.is_ignored(entry.path, false))
                continue :func
            else
                return .{ .file = entry.path },

            else => {},
        }
    }
    return null;
}
pub fn is_ignored(self: @This(), path: []const u8, is_dir: bool) bool {
    var ignored = false;
    for (default_ignore) |glob|
        if (glob.match(path, is_dir)) {
            ignored = !glob.negated;
        };
    for (self.ignore_list.items) |glob|
        if (glob.match(path, is_dir)) {
            ignored = !glob.negated;
        };
    return ignored;
}
