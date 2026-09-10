const std = @import("std");

pub const Level = enum(u8) {
    quiet = 0,
    err = 1,
    warn = 2,
    info = 3,
    debug = 4,

    pub fn label(self: Level) []const u8 {
        return @tagName(self);
    }

    pub fn parse(str: []const u8) ?Level {
        inline for (@typeInfo(Level).@"enum".fields) |f| {
            if (std.mem.eql(u8, str, f.name))
                return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const Style = enum {
    reset,
    bold,
    dim,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,

    pub fn code(self: Style) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
        };
    }
};

rw_io: struct { std.Io.File, std.Io.File },
rw_file: struct { std.Io.File.Reader, std.Io.File.Writer },
rw_buf: struct { []u8, []u8 },

log_level: Level = .debug,
timestamps: bool = true,
io: std.Io,
color: bool,

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
        .color = wo.isTty(io) catch false,
        .io = io,
    };
}

pub inline fn reader(self: *@This()) *std.Io.Reader {
    return &self.rw_file.@"0".interface;
}

pub inline fn writer(self: *@This()) *std.Io.Writer {
    return &self.rw_file.@"1".interface;
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
    _ = io;
    alloc.free(self.rw_buf.@"0");
    alloc.free(self.rw_buf.@"1");
}

pub inline fn flush(self: *@This()) !void {
    try self.writer().flush();
}

pub inline fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    try self.writer().print(fmt, args);
    try self.flush();
}

pub inline fn println(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    try self.writer().print(fmt ++ "\n", args);
    try self.flush();
}

pub inline fn write(self: *@This(), txt: []const u8) !void {
    try self.writer().writeAll(txt);
}
pub inline fn byte(self: *@This(), b: u8) !void {
    try self.writer().writeByte(b);
}

pub fn read_till(self: *@This(), buf: []u8, tk: u8) ![]u8 {
    for (buf, 0..) |*c, i| {
        c.* = try self.reader().takeByte();
        if (c.* == tk)
            return buf[0..i];
    }
    return buf;
}

pub inline fn read_line(self: *@This(), buf: []u8) ![]u8 {
    return self.read_till(buf, '\n');
}

pub fn style(self: *@This(), s: Style) void {
    if (!self.color) return;
    self.write(s.code()) catch {};
}

pub fn styled(self: *@This(), s: Style, txt: []const u8) void {
    if (!self.color) {
        self.write(txt) catch {};
        return;
    }
    self.write(s.code()) catch {};
    self.write(txt) catch {};
    self.write(Style.reset.code()) catch {};
}

fn write_timestamp(self: *@This(), w: *std.Io.Writer) !void {
    if (!self.timestamps) return;
    const io = self.io;
    const ts = std.Io.Clock.now(.real, io);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, ts.toSeconds())) };
    const day = es.getDaySeconds();
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    if (self.color) {
        try w.print("{c}[2m{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}{c}[0m ", .{
            0x1b,                       yd.year,
            @intFromEnum(md.month),     md.day_index + 1,
            day.getHoursIntoDay(),      day.getMinutesIntoHour(),
            day.getSecondsIntoMinute(), 0x1b,
        });
    } else {
        try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{
            yd.year,
            @intFromEnum(md.month),
            md.day_index + 1,
            day.getHoursIntoDay(),
            day.getMinutesIntoHour(),
            day.getSecondsIntoMinute(),
        });
    }
}

pub fn logf(self: *@This(), comptime level: Level, comptime fmt: []const u8, args: anytype) !void {
    if (@intFromEnum(level) > @intFromEnum(self.log_level)) return;
    const w = self.writer();
    try self.write_timestamp(w);
    if (self.color) {
        try w.writeAll(comptime tag(level, true));
    } else {
        try w.writeAll(comptime tag(level, false));
    }
    try w.print(fmt ++ "\n", args);
    try w.flush();
}

fn tag(comptime level: Level, comptime colored: bool) []const u8 {
    if (colored) {
        return switch (level) {
            .quiet => "",
            .err => Style.red.code() ++ Style.bold.code() ++ "error" ++ Style.reset.code() ++ Style.red.code() ++ ":" ++ Style.reset.code() ++ " ",
            .warn => Style.yellow.code() ++ "warn" ++ Style.reset.code() ++ ": ",
            .info => Style.green.code() ++ "info" ++ Style.reset.code() ++ ": ",
            .debug => Style.dim.code() ++ "debug" ++ Style.reset.code() ++ ": ",
        };
    }
    return switch (level) {
        .quiet => "",
        .err => "error: ",
        .warn => "warn: ",
        .info => "info: ",
        .debug => "debug: ",
    };
}

pub fn err(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    try self.logf(.err, fmt, args);
}

pub fn warn(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    try self.logf(.warn, fmt, args);
}

pub fn info(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    try self.logf(.info, fmt, args);
}

pub fn debug(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    try self.logf(.debug, fmt, args);
}

pub fn op(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    if (@intFromEnum(Level.info) > @intFromEnum(self.log_level)) return;
    const w = self.writer();
    try self.write_timestamp(w);
    if (self.color) try w.writeAll(Style.bold.code() ++ ">> ") else try w.writeAll(">> ");
    if (self.color) try w.writeAll(Style.reset.code());
    try w.print(fmt ++ "\n", args);
    try w.flush();
}

pub fn success(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
    if (@intFromEnum(Level.info) > @intFromEnum(self.log_level)) return;
    const w = self.writer();
    try self.write_timestamp(w);
    if (self.color) {
        try w.writeAll(Style.bold.code());
        try w.writeAll(Style.green.code());
        try w.writeAll("ok");
        try w.writeAll(Style.reset.code());
        try w.writeAll(": ");
    } else {
        try w.writeAll("ok: ");
    }
    try w.print(fmt ++ "\n", args);
    try w.flush();
}
