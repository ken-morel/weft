const std = @import("std");
const builtin = @import("builtin");

pub const Color = std.Io.Terminal.Color;

pub const Size = struct {
    rows: u16,
    cols: u16,
};

const default_size: Size = .{ .rows = 24, .cols = 80 };

file: std.Io.File,
file_writer: std.Io.File.Writer,
buffer: []u8,
mode: std.Io.Terminal.Mode,
is_tty: bool,
io: std.Io,
mutex: std.Io.Mutex = .init,

pub fn init(gpa: std.mem.Allocator, io: std.Io) !@This() {
    const file = std.Io.File.stdout();
    const buffer = try gpa.alloc(u8, 4 << 10);
    const mode = std.Io.Terminal.Mode.detect(io, file, false, false) catch .no_color;
    return .{
        .file = file,
        .file_writer = file.writer(io, buffer),
        .buffer = buffer,
        .mode = mode,
        .is_tty = mode == .escape_codes,
        .io = io,
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, _: std.Io) void {
    gpa.free(self.buffer);
}

pub inline fn writer(self: *@This()) *std.Io.Writer {
    return &self.file_writer.interface;
}

pub inline fn flush(self: *@This()) !void {
    try self.writer().flush();
}

fn terminal(self: *@This()) std.Io.Terminal {
    return .{ .writer = self.writer(), .mode = self.mode };
}

fn color_unlocked(self: *@This(), color: Color) void {
    const t = self.terminal();
    if (self.mode == .windows_api)
        t.writer.flush() catch {};
    t.setColor(color) catch {};
}

fn escape_unlocked(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    if (self.is_tty)
        self.writer().print(fmt, args) catch {};
}

fn escape(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    if (!self.is_tty)
        return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.escape_unlocked(fmt, args);
}

pub fn set_color(self: *@This(), color: Color) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.color_unlocked(color);
}

pub fn set_reverse(self: *@This(), enable: bool) void {
    if (enable)
        self.escape("\x1b[7m", .{})
    else
        self.escape("\x1b[27m", .{});
}

pub fn clear_line(self: *@This()) void {
    self.escape("\x1b[2K\r", .{});
}

pub fn clear_to_end(self: *@This()) void {
    self.escape("\x1b[J", .{});
}

pub fn move_up(self: *@This(), n: u16) void {
    if (n > 0)
        self.escape("\x1b[{d}A", .{n});
}

pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.writer().print(fmt, args) catch {};
    self.flush() catch {};
}

pub fn println(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    self.print(fmt ++ "\n", args);
}

pub fn styled(self: *@This(), color: Color, comptime fmt: []const u8, args: anytype) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.color_unlocked(color);
    self.writer().print(fmt, args) catch {};
    self.color_unlocked(.reset);
    self.flush() catch {};
}

pub fn styled_ln(self: *@This(), color: Color, comptime fmt: []const u8, args: anytype) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.color_unlocked(color);
    self.writer().print(fmt, args) catch {};
    self.color_unlocked(.reset);
    self.writer().writeByte('\n') catch {};
    self.flush() catch {};
}

pub fn get_size(self: *@This()) Size {
    return if (!(self.file.isTty(self.io) catch false))
        default_size
    else if (builtin.os.tag == .windows)
        windows_size(self.io, self.file)
    else
        posix_size(self.io, self.file);
}

fn windows_size(io: std.Io, file: std.Io.File) Size {
    var info = std.os.windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO;
    const status = info.operate(io, file) catch return default_size;
    const window = info.Data.dwWindowSize;
    return if (status == .SUCCESS and window.X > 0 and window.Y > 0)
        .{ .rows = @intCast(window.Y), .cols = @intCast(window.X) }
    else
        default_size;
}

fn posix_size(io: std.Io, file: std.Io.File) Size {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const res = io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return default_size;
    return if (res.device_io_control >= 0 and ws.row > 0 and ws.col > 0)
        .{ .rows = ws.row, .cols = ws.col }
    else
        default_size;
}

fn timestamp_unlocked(self: *@This()) void {
    const ts = std.Io.Clock.now(.real, self.io);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, ts.toSeconds())) };
    const day = es.getDaySeconds();
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    self.color_unlocked(.dim);
    self.writer().print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{
        yd.year,
        @backingInt(md.month),
        md.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    }) catch {};
    self.color_unlocked(.reset);
}

fn tagged(
    self: *@This(),
    timestamp: bool,
    tag_color: Color,
    tag_text: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.escape_unlocked("\x1b[2K\r", .{});
    if (timestamp)
        self.timestamp_unlocked();
    self.color_unlocked(tag_color);
    self.writer().writeAll(tag_text) catch {};
    self.color_unlocked(.reset);
    self.writer().print(fmt ++ "\n", args) catch {};
    self.flush() catch {};
}

pub fn write_event(self: *@This(), tag_color: Color, tag_text: []const u8, comptime fmt: []const u8, args: anytype) void {
    self.tagged(false, tag_color, tag_text, fmt, args);
}

pub fn success(self: *@This(), comptime fmt: []const u8, args: anytype) void {
    self.tagged(true, .green, "ok: ", fmt, args);
}

const task_palette = [_]Color{
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
    var idx: u8 = 0x55;
    for (name) |c|
        idx *%= c;
    return task_palette[idx % task_palette.len];
}

fn task_log_unlocked(self: *@This(), color: Color, prefix: []const u8, line: []const u8, width: usize) !void {
    const w = self.writer();
    const separator = " │ ";
    const gutter = prefix.len + 3;
    const line_width = if (width > gutter + 10) width - gutter else 10;

    self.escape_unlocked("\x1b[2K\r", .{});
    self.color_unlocked(color);
    try w.writeAll(prefix);
    try w.writeAll(separator);
    self.color_unlocked(.reset);

    var rest = line;
    while (true) {
        const take = @min(line_width, rest.len);
        try w.writeAll(rest[0..take]);
        try w.writeByte('\n');
        rest = rest[take..];
        if (rest.len == 0)
            break;
        try w.splatByteAll(' ', prefix.len);
        try w.writeAll(separator);
    }
}

pub fn print_logs(self: *@This(), task: []const u8, content: []const u8) !void {
    const color = task_color(task);
    const width = self.get_size().cols;

    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, content, "\r\n"), '\n');
    while (lines.next()) |line|
        try self.task_log_unlocked(color, task, std.mem.trimEnd(u8, line, "\r"), width);
    try self.flush();
}
