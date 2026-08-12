const std = @import("std");

rw_io: struct { std.Io.File, std.Io.File },
rw_file: struct { std.Io.File.Reader, std.Io.File.Writer },
rw_buf: struct { []u8, []u8 },

pub fn init(alloc: std.mem.Allocator, io: std.Io) !@This() {
    var ri = std.Io.File.stdin();
    var wo = std.Io.File.stdout();

    const wo_buf = try alloc.alloc(u8, 4 << 10);
    errdefer alloc.free(wo_buf);

    const ri_buf = try alloc.alloc(u8, 4 << 10);
    errdefer alloc.free(ri_buf);

    return .{
        .rw_io = .{ ri, wo },
        .rw_file = .{ ri.reader(io, ri_buf), wo.writer(io, wo_buf) },
        .rw_buf = .{ ri_buf, wo_buf },
    };
}

pub fn reader(self: *@This()) *std.Io.Reader {
    return &self.rw_file.@"0".interface;
}

pub fn writer(self: *@This()) *std.Io.Writer {
    return &self.rw_file.@"1".interface;
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
    _ = io;
    alloc.free(self.rw_buf.@"0");
    alloc.free(self.rw_buf.@"1");
}

pub fn flush(self: *@This()) !void {
    try self.writer().flush();
}

pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    try self.writer().print(fmt, args);
}

pub fn println(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    try self.print(fmt ++ "\n", args);
}

pub fn err(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    try self.print(fmt ++ "\n", args);
}

pub fn write(self: *@This(), txt: []const u8) !void {
    try self.writer().writeAll(txt);
}

pub fn newline(self: *@This()) !void {
    try self.writer().writeByte('\n');
}

pub fn line_return(self: *@This()) !void {
    try self.writer().writeByte('\r');
}

pub fn read_till(self: *@This(), buf: []u8, tk: u8) ![]u8 {
    for (buf, 0..) |*c, i| {
        c.* = try self.reader().takeByte();
        if (c.* == tk)
            return buf[0..i];
    }
    return buf;
}

pub fn read_line(self: *@This(), buf: []u8) ![]u8 {
    return self.read_till(buf, '\n');
}
