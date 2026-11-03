const std = @import("std");

raw: []const u8,
store_path: []const u8,
url: []const u8,
compression: []const u8,
file_hash: ?[]const u8 = null,
file_size: u64 = 0,
nar_hash: []const u8,
nar_size: u64 = 0,
references: []const u8 = "",
deriver: ?[]const u8 = null,
sig: ?[]const u8 = null,

pub fn parse(data: []const u8) ?@This() {
    var result: @This() = .{
        .raw = data,
        .store_path = "",
        .url = "",
        .compression = "",
        .nar_hash = "",
    };

    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (line.len == 0)
            continue;
        if (val("StorePath:", line)) |v|
            result.store_path = v
        else if (val("URL:", line)) |v|
            result.url = v
        else if (val("Compression:", line)) |v|
            result.compression = v
        else if (val("FileHash:", line)) |v|
            result.file_hash = v
        else if (val("FileSize:", line)) |v|
            result.file_size = std.fmt.parseInt(u64, v, 10) catch 0
        else if (val("NarHash:", line)) |v|
            result.nar_hash = v
        else if (val("NarSize:", line)) |v|
            result.nar_size = std.fmt.parseInt(u64, v, 10) catch 0
        else if (val("References:", line)) |v|
            result.references = v
        else if (val("Deriver:", line)) |v|
            result.deriver = v
        else if (val("Sig:", line)) |v|
            result.sig = v;
    }

    return if (result.store_path.len == 0 or result.url.len == 0)
        null
    else
        result;
}

fn val(prefix: []const u8, line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, prefix))
        return null;
    return std.mem.trim(u8, line[prefix.len..], " \r");
}
pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
    gpa.free(self.raw);
}

pub fn fetch(gpa: std.mem.Allocator, client: *std.http.Client, hash: []const u8) !@This() {
    const key = if (hash.len >= 32) hash[0..32] else hash;
    const url = try gpa.print("https://cache.nixos.org/{s}.narinfo", .{key});
    defer gpa.free(url);

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();
    const res = try client.fetch(
        .{
            .location = .{ .url = url },
            .response_writer = &allocating.writer,
        },
    );
    switch (res.status) {
        .ok => {},
        else => return error.InvalidHttpResponse,
    }
    const data = try allocating.toOwnedSlice();
    errdefer gpa.free(data);
    return @This().parse(data) orelse error.InvalidNarInfo;
}
pub fn deps(self: @This()) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, self.references, ' ');
}
pub fn has_deps(self: @This()) bool {
    return std.mem.trim(u8, self.references, " \t\n").len != 0;
}
