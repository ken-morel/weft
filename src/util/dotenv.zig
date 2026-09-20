const std = @import("std");

pub const Map = std.StringHashMapUnmanaged([]const u8);

pub const DotEnv = struct {
    content: ?[]const u8,
    map: Map,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
        if (self.content) |c|
            alloc.free(c);
    }

    pub fn get(self: @This(), key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};

pub fn parse(alloc: std.mem.Allocator, content: []const u8) !Map {
    var map: Map = .empty;
    errdefer map.deinit(alloc);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#')
            continue;

        const trimmed = if (std.mem.startsWith(u8, line, "export "))
            std.mem.trim(u8, line[7..], " \t")
        else
            line;

        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
        if (key.len == 0)
            continue;

        var val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\'')))
            val = val[1 .. val.len - 1];

        try map.put(alloc, key, val);
    }

    return map;
}

pub fn load(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !DotEnv {
    const content = dir.readFileAllocOptions(
        io,
        ".env",
        alloc,
        .limited(1 << 20),
        .of(u8),
        0,
    ) catch |err|
        if (err == error.FileNotFound)
            return .{ .content = null, .map = .empty }
        else
            return err;
    errdefer alloc.free(content);

    const map = try parse(alloc, content);
    return .{
        .content = content,
        .map = map,
    };
}
