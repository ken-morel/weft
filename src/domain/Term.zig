const std = @import("std");
pub const Color = std.Io.Terminal.Color;

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
        inline for (@typeInfo(Level).@"enum".fields) |f|
            if (std.mem.eql(u8, str, f.name))
                return @enumFromInt(f.value);

        return null;
    }
};

stdin_file: std.Io.File,
stdout_file: std.Io.File,
reader_file: std.Io.File.Reader,
writer_file: std.Io.File.Writer,
in_buf: []u8,
out_buf: []u8,
terminal: std.Io.Terminal,

log_level: Level = .debug,
timestamps: bool = true,
io: std.Io,
is_tty: bool,
mutex: std.Io.Mutex = .init,

pub fn init(alloc: std.mem.Allocator, io: std.Io) !@This() {
    var stdin_file = std.Io.File.stdin();
    var stdout_file = std.Io.File.stdout();

    const out_buf = try alloc.alloc(u8, 4 << 10);
    errdefer alloc.free(out_buf);

    const in_buf = try alloc.alloc(u8, 4 << 10);
    errdefer alloc.free(in_buf);

    const is_tty = stdout_file.isTty(io) catch false;
    const mode = std.Io.Terminal.Mode.detect(io, stdout_file, false, false) catch .no_color;

    var self: @This() = .{
        .stdin_file = stdin_file,
        .stdout_file = stdout_file,
        .reader_file = stdin_file.reader(io, in_buf),
        .writer_file = stdout_file.writer(io, out_buf),
        .in_buf = in_buf,
        .out_buf = out_buf,
        .terminal = .{
            .writer = undefined,
            .mode = mode,
        },
        .is_tty = is_tty,
        .io = io,
    };
    self.terminal.writer = &self.writer_file.interface;
    return self;
}

pub fn deinit(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
    _ = io;
    alloc.free(self.in_buf);
    alloc.free(self.out_buf);
}

pub inline fn reader(self: *@This()) *std.Io.Reader {
    return &self.reader_file.interface;
}

pub inline fn writer(self: *@This()) *std.Io.Writer {
    return &self.writer_file.interface;
}

pub inline fn flush(self: *@This()) !void {
    try self.writer().flush();
}

pub fn set_color(self: *@This(), color: Color) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    self.terminal.setColor(color) catch {};
}

pub fn set_reverse(self: *@This(), enable: bool) void {
    if (!self.is_tty or self.terminal.mode != .escape_codes) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.writer().writeAll(if (enable) "\x1b[7m" else "\x1b[27m") catch {};
}

pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.writer().print(fmt, args) catch return;
    self.flush() catch return;
}

pub fn println(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.writer().print(fmt ++ "\n", args) catch return;
    self.flush() catch return;
}

pub fn styled(self: *@This(), color: Color, comptime fmt: []const u8, args: anytype) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.terminal.writer = &self.writer_file.interface;
    self.terminal.setColor(color) catch {};
    self.writer().print(fmt, args) catch {};
    self.terminal.setColor(.reset) catch {};
    self.flush() catch return;
}

pub fn styled_ln(self: *@This(), color: Color, comptime fmt: []const u8, args: anytype) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.terminal.writer = &self.writer_file.interface;
    self.terminal.setColor(color) catch {};
    self.writer().print(fmt, args) catch {};
    self.terminal.setColor(.reset) catch {};
    self.writer().writeByte('\n') catch {};
    self.flush() catch return;
}

pub fn clear_line(self: *@This()) void {
    if (!self.is_tty) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.writer().writeAll("\x1b[2K\r") catch {};
}

pub fn clear_to_end(self: *@This()) void {
    if (!self.is_tty) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.writer().writeAll("\x1b[J") catch {};
}

pub fn move_up(self: *@This(), n: u16) void {
    if (n == 0 or !self.is_tty) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.writer().print("\x1b[{d}A", .{n}) catch {};
}

pub fn move_down(self: *@This(), n: u16) void {
    if (n == 0 or !self.is_tty) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.writer().print("\x1b[{d}B", .{n}) catch {};
}

pub fn hide_cursor(self: *@This()) void {
    if (!self.is_tty) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.writer().writeAll("\x1b[?25l") catch {};
}

pub fn show_cursor(self: *@This()) void {
    if (!self.is_tty) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.writer().writeAll("\x1b[?25h") catch {};
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

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub fn get_size(self: *@This()) Size {
    if (self.is_tty) {
        var ws: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const res = self.io.operate(.{ .device_io_control = .{
            .file = self.stdout_file,
            .code = std.posix.T.IOCGWINSZ,
            .arg = &ws,
        } }) catch null;

        if (res) |r|
            if (r.device_io_control >= 0 and ws.row > 0 and ws.col > 0)
                return .{ .rows = ws.row, .cols = ws.col };
    }
    return .{ .rows = 24, .cols = 80 };
}

fn write_timestamp_unlocked(self: *@This(), w: *std.Io.Writer) !void {
    const ts = std.Io.Clock.now(.real, self.io);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, ts.toSeconds())) };
    const day = es.getDaySeconds();
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    self.terminal.writer = &self.writer_file.interface;
    self.terminal.setColor(.dim) catch {};
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{
        yd.year,
        @intFromEnum(md.month),
        md.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
    self.terminal.setColor(.reset) catch {};
}

pub fn write_tag(self: *@This(), tag_color: Color, tag_text: []const u8, comptime fmt: []const u8, args: anytype) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const w = self.writer();
    if (self.is_tty) w.writeAll("\x1b[2K\r") catch {};
    if (self.timestamps) self.write_timestamp_unlocked(w) catch {};
    self.terminal.writer = &self.writer_file.interface;
    self.terminal.setColor(tag_color) catch {};
    w.writeAll(tag_text) catch {};
    self.terminal.setColor(.reset) catch {};
    w.print(fmt ++ "\n", args) catch {};
    w.flush() catch {};
}

pub const task_palette = [_]Color{
    .cyan,
    .bright_yellow,
    .magenta,
    .bright_blue,
    .bright_cyan,
    .bright_magenta,
    .green,
    .yellow,
    .bright_green,
};

pub fn task_color(name: []const u8) Color {
    var idx: u8 = 0;
    for (name) |c|
        idx *%= c;
    return task_palette[idx % task_palette.len];
}

pub fn write_task_log(self: *@This(), color: Color, prefix: []const u8, line: []const u8) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const w = self.writer();
    if (self.is_tty) w.writeAll("\x1b[2K\r") catch {};
    self.terminal.writer = &self.writer_file.interface;
    self.terminal.setColor(color) catch {};
    w.writeAll(prefix) catch {};
    w.writeAll(" │ ") catch {};
    self.terminal.setColor(.reset) catch {};
    w.writeAll(line) catch {};
    w.writeByte('\n') catch {};
    w.flush() catch {};
}

pub fn write_event(self: *@This(), tag_color: Color, tag_text: []const u8, comptime fmt: []const u8, args: anytype) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const w = self.writer();
    if (self.is_tty) w.writeAll("\x1b[2K\r") catch {};
    self.terminal.writer = &self.writer_file.interface;
    self.terminal.setColor(tag_color) catch {};
    w.writeAll(tag_text) catch {};
    self.terminal.setColor(.reset) catch {};
    w.print(fmt ++ "\n", args) catch {};
    w.flush() catch {};
}

pub fn logf(self: *@This(), comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(self.log_level))
        return;
    const color, const prefix = switch (level) {
        .quiet => return,
        .err => .{ .red, "error: " },
        .warn => .{ .yellow, "warn: " },
        .info => .{ .green, "info: " },
        .debug => .{ .dim, "debug: " },
    };
    self.write_tag(color, prefix, fmt, args);
}

pub inline fn err(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    self.logf(.err, fmt, args);
}

pub inline fn warn(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    self.logf(.warn, fmt, args);
}

pub inline fn info(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    self.logf(.info, fmt, args);
}

pub inline fn debug(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    self.logf(.debug, fmt, args);
}

pub inline fn op(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(Level.info) > @intFromEnum(self.log_level))
        return;
    self.write_tag(.bold, ">> ", fmt, args);
}

pub inline fn success(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(Level.info) > @intFromEnum(self.log_level))
        return;
    self.write_tag(.green, "ok: ", fmt, args);
}
