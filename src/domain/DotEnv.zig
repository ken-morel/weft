const std = @import("std");

registers: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),

pub fn load_leaky(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !@This() {
    var iter_dir = try dir.openDir(io, ".", .{ .iterate = true });
    defer iter_dir.close(io);
    var registers: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)) = .empty;

    // damn, 2KB of stack space
    var iter = iter_dir.iterate();
    while (try iter.next(io)) |entry| {
        const name = if (std.mem.eql(u8, entry.name, ".env"))
            &.{}
        else if (std.mem.startsWith(u8, entry.name, ".env."))
            entry.name[5..]
        else
            continue;

        const map = try load_file_leaky(
            alloc,
            io,
            dir,
            entry.name,
        );
        try registers.put(alloc, try alloc.dupe(u8, name), map);
    }
    return .{
        .registers = registers,
    };
}
pub fn get(self: @This(), register_name: ?[]const u8, name: []const u8) ?[]const u8 {
    if (register_name) |r_name|
        if (self.registers.get(r_name)) |r|
            if (r.get(name)) |v|
                return v;
    return if (self.registers.get("")) |default|
        default.get(name)
    else
        null;
}

pub fn parse_into(alloc: std.mem.Allocator, map: *std.StringHashMapUnmanaged([]const u8), content: []const u8) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#')
            continue;

        const trimmed = if (std.mem.startsWith(u8, line, "export "))
            std.mem.trimStart(u8, line[7..], " \t")
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

pub fn parse(alloc: std.mem.Allocator, content: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer map.deinit(alloc);
    try parse_into(alloc, &map, content);
    return map;
}

//TODO: Make DotEnv a struct which will cache the results of this load_env

pub fn load_file_leaky(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, filename: []const u8) !std.StringHashMapUnmanaged([]const u8) {
    var env: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer env.deinit(alloc);
    const content = try dir.readFileAlloc(io, filename, alloc, .unlimited);
    try parse_into(alloc, &env, content);
    return env;
}
