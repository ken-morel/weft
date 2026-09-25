const std = @import("std");

pub const Map = std.StringHashMapUnmanaged([]const u8);

pub const DotEnv = struct {
    contents: std.ArrayListUnmanaged([]const u8) = .empty,
    map: Map = .empty,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
        for (self.contents.items) |c|
            alloc.free(c);
        self.contents.deinit(alloc);
    }

    pub fn get(self: @This(), key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};

pub fn parse_into(alloc: std.mem.Allocator, map: *Map, content: []const u8) !void {
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
}

pub fn parse(alloc: std.mem.Allocator, content: []const u8) !Map {
    var map: Map = .empty;
    errdefer map.deinit(alloc);
    try parse_into(alloc, &map, content);
    return map;
}

pub fn load_for_remote(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, remote: ?[]const u8) !DotEnv {
    var result: DotEnv = .{};
    errdefer result.deinit(alloc);

    if (dir.readFileAllocOptions(io, ".env", alloc, .limited(1 << 20), .of(u8), 0)) |base_content| {
        try result.contents.append(alloc, base_content);
        try parse_into(alloc, &result.map, base_content);
    } else |err| if (err != error.FileNotFound) {
        return err;
    }

    if (remote) |r| {
        if (r.len > 0) {
            const remote_env_name = try std.fmt.allocPrint(alloc, ".env.{s}", .{r});
            defer alloc.free(remote_env_name);

            if (dir.readFileAllocOptions(io, remote_env_name, alloc, .limited(1 << 20), .of(u8), 0)) |remote_content| {
                try result.contents.append(alloc, remote_content);
                try parse_into(alloc, &result.map, remote_content);
            } else |err| if (err != error.FileNotFound) {
                return err;
            }
        }
    }

    return result;
}

pub fn load(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !DotEnv {
    return load_for_remote(alloc, io, dir, null);
}
