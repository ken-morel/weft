const std = @import("std");
const builtin = @import("builtin");

const cgroup_root = "/sys/fs/cgroup";
const cgroup_procs = "cgroup.procs";
const cgroup_kill = "cgroup.kill";
const cgroup_freeze = "cgroup.freeze";
const cgroup_events = "cgroup.events";
const cgroup_subtree_control = "cgroup.subtree_control";
const cgroup_controllers = "cgroup.controllers";
const pids_max = "pids.max";
const pids_current = "pids.current";
const memory_max = "memory.max";
const memory_high = "memory.high";
const memory_current = "memory.current";
const memory_peak = "memory.peak";
const memory_swap_max = "memory.swap.max";
const memory_oom_group = "memory.oom.group";
const cpu_max = "cpu.max";
const cpu_stat = "cpu.stat";
const cpu_weight = "cpu.weight";
const io_weight = "io.weight";

path: []const u8,

pub const Events = struct {
    populated: bool = false,
    frozen: bool = false,
};

pub const CpuStat = struct {
    usage_usec: u64 = 0,
    user_usec: u64 = 0,
    system_usec: u64 = 0,
    nr_periods: u64 = 0,
    nr_throttled: u64 = 0,
    throttled_usec: u64 = 0,
};

pub const CpuMax = struct {
    quota: ?u64 = null,
    period: u64 = 100000,
};

pub fn init_absolute_take(path: []const u8) @This() {
    return .{
        .path = path,
    };
}

pub fn init_absolute(gpa: std.mem.Allocator, path: []const u8) !@This() {
    return .init_absolute_take(try gpa.dupe(u8, path));
}

pub fn init(gpa: std.mem.Allocator, name: []const u8) !@This() {
    return .init_absolute_take(try std.fs.path.join(gpa, &.{ cgroup_root, name }));
}

pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
    gpa.free(self.path);
}

pub fn create(self: @This(), io: std.Io) !void {
    return try std.Io.Dir.cwd().createDirPath(io, self.path);
}

pub fn destroy(self: @This(), io: std.Io) !void {
    return try std.Io.Dir.cwd().deleteDir(io, self.path);
}

pub fn child(self: @This(), gpa: std.mem.Allocator, sub_name: []const u8) !@This() {
    return .init_absolute_take(try std.fs.path.join(gpa, &.{ self.path, sub_name }));
}

pub inline fn _write(gpa: std.mem.Allocator, io: std.Io, g: []const u8, n: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(gpa, &.{ g, n });
    defer gpa.free(path);
    var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only });
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

pub inline fn _readalloc(gpa: std.mem.Allocator, io: std.Io, g: []const u8, n: []const u8) ![:0]const u8 {
    const path = try std.fs.path.join(gpa, &.{ g, n });
    defer gpa.free(path);
    return try std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
}

pub inline fn _readbuf(gpa: std.mem.Allocator, io: std.Io, g: []const u8, n: []const u8, buf: []u8) ![]const u8 {
    const path = try std.fs.path.join(gpa, &.{ g, n });
    defer gpa.free(path);
    return try std.Io.Dir.cwd().readFile(io, path, buf);
}

pub fn procs_list(self: @This(), gpa: std.mem.Allocator, io: std.Io) ![]i64 {
    const path = try std.fs.path.join(gpa, &.{ self.path, cgroup_procs });
    defer gpa.free(path);
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var pos: usize = 0;
    var buffer: [20]u8 = undefined;
    var pids: std.ArrayListUnmanaged(i64) = .empty;
    defer pids.deinit(gpa);

    var n_read = try f.readPositional(io, &.{&buffer}, pos);
    while (n_read != 0) : (n_read = try f.readPositional(io, &.{&buffer}, pos)) {
        const read = buffer[0..n_read];
        const end = std.mem.findScalar(u8, read, '\n') orelse read.len;
        pos += end + 1;
        const num = try std.fmt.parseInt(i64, read[0..end], 10);
        try pids.append(gpa, num);
    }
    return try pids.toOwnedSlice(gpa);
}

pub fn procs_add(self: @This(), gpa: std.mem.Allocator, io: std.Io, pid: i64) !void {
    const write = try gpa.print("{d}\n", .{pid});
    defer gpa.free(write);
    try _write(gpa, io, self.path, cgroup_procs, write);
}

pub fn self_pid() i64 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => std.os.linux.getpid(),
        else => std.posix.system.getpid(),
    };
}

pub fn kill(self: @This(), gpa: std.mem.Allocator, io: std.Io) !void {
    return try _write(gpa, io, self.path, cgroup_kill, "1");
}

pub fn frozen_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, val: bool) !void {
    return try _write(
        gpa,
        io,
        self.path,
        cgroup_freeze,
        if (val)
            "1"
        else
            "0",
    );
}

pub fn frozen_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !bool {
    var buf: [2]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, cgroup_freeze, &buf);
    return if (content.len > 0 and content[0] == '1')
        true
    else if (content.len > 0 and content[0] == '0')
        false
    else
        error.Unexpected;
}

pub fn pids_max_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, val: ?u64) !void {
    const write = if (val) |v|
        try gpa.print("{d}", .{v})
    else
        null;
    defer if (write) |w|
        gpa.free(w);
    try _write(gpa, io, self.path, pids_max, write orelse "max");
}

pub fn pids_max_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !?u64 {
    var buf: [32]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, pids_max, &buf);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return if (std.mem.eql(u8, trimmed, "max"))
        null
    else
        try std.fmt.parseInt(u64, trimmed, 10);
}

pub fn pids_current_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !u32 {
    var buf: [32]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, pids_current, &buf);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return try std.fmt.parseInt(u32, trimmed, 10);
}

pub fn subtree_control_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, controllers: []const u8) !void {
    return try _write(gpa, io, self.path, cgroup_subtree_control, controllers);
}

pub fn subtree_control_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) ![:0]const u8 {
    return try _readalloc(gpa, io, self.path, cgroup_subtree_control);
}

pub fn controllers_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) ![:0]const u8 {
    return try _readalloc(gpa, io, self.path, cgroup_controllers);
}

pub fn events_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !Events {
    var buf: [128]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, cgroup_events, &buf);
    var ev: Events = .{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "populated ")) {
            const val = std.mem.trim(u8, line["populated ".len..], " \t\r\n");
            ev.populated = std.mem.eql(u8, val, "1");
        } else if (std.mem.startsWith(u8, line, "frozen ")) {
            const val = std.mem.trim(u8, line["frozen ".len..], " \t\r\n");
            ev.frozen = std.mem.eql(u8, val, "1");
        } else {}
    }
    return ev;
}

pub fn is_active(self: @This(), gpa: std.mem.Allocator, io: std.Io) bool {
    var buf: [16]u8 = undefined;
    const content = _readbuf(gpa, io, self.path, cgroup_procs, &buf) catch return false;
    return content.len > 0;
}

pub fn memory_max_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, val: ?u64) !void {
    const write = if (val) |v|
        try gpa.print("{d}", .{v})
    else
        null;
    defer if (write) |w|
        gpa.free(w);
    try _write(gpa, io, self.path, memory_max, write orelse "max");
}

pub fn memory_max_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !?u64 {
    var buf: [32]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, memory_max, &buf);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return if (std.mem.eql(u8, trimmed, "max"))
        null
    else
        try std.fmt.parseInt(u64, trimmed, 10);
}

pub fn memory_high_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, val: ?u64) !void {
    const write = if (val) |v|
        try gpa.print("{d}", .{v})
    else
        null;
    defer if (write) |w|
        gpa.free(w);
    try _write(gpa, io, self.path, memory_high, write orelse "max");
}

pub fn memory_high_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !?u64 {
    var buf: [32]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, memory_high, &buf);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return if (std.mem.eql(u8, trimmed, "max"))
        null
    else
        try std.fmt.parseInt(u64, trimmed, 10);
}

pub fn memory_current_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !u64 {
    var buf: [32]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, memory_current, &buf);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return try std.fmt.parseInt(u64, trimmed, 10);
}

pub fn memory_peak_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !u64 {
    var buf: [32]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, memory_peak, &buf);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return try std.fmt.parseInt(u64, trimmed, 10);
}

pub fn memory_swap_max_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, val: ?u64) !void {
    const write = if (val) |v|
        try gpa.print("{d}", .{v})
    else
        null;
    defer if (write) |w|
        gpa.free(w);
    try _write(gpa, io, self.path, memory_swap_max, write orelse "max");
}

pub fn memory_swap_max_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !?u64 {
    var buf: [32]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, memory_swap_max, &buf);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return if (std.mem.eql(u8, trimmed, "max"))
        null
    else
        try std.fmt.parseInt(u64, trimmed, 10);
}

pub fn memory_oom_group_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, val: bool) !void {
    return try _write(
        gpa,
        io,
        self.path,
        memory_oom_group,
        if (val)
            "1"
        else
            "0",
    );
}

pub fn memory_oom_group_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !bool {
    var buf: [2]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, memory_oom_group, &buf);
    return if (content.len > 0 and content[0] == '1')
        true
    else if (content.len > 0 and content[0] == '0')
        false
    else
        error.Unexpected;
}

pub fn cpu_max_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, quota: ?u64, period: ?u64) !void {
    const p = period orelse 100000;
    const write = if (quota) |q|
        try gpa.print("{d} {d}", .{ q, p })
    else
        try gpa.print("max {d}", .{p});
    defer gpa.free(write);
    try _write(gpa, io, self.path, cpu_max, write);
}

pub fn cpu_quota_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, quota_pct: ?u16) !void {
    const quota: ?u64 = if (quota_pct) |qp|
        @as(u64, qp) * 1000
    else
        null;
    try self.cpu_max_set(gpa, io, quota, 100000);
}

pub fn cpu_max_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !CpuMax {
    var buf: [64]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, cpu_max, &buf);
    var it = std.mem.tokenizeScalar(u8, content, ' ');
    const quota_str = it.next() orelse return error.Unexpected;
    const period_str = it.next() orelse "100000";
    const quota: ?u64 = if (std.mem.eql(u8, quota_str, "max"))
        null
    else
        try std.fmt.parseInt(u64, quota_str, 10);
    const period = try std.fmt.parseInt(u64, std.mem.trim(u8, period_str, " \t\r\n"), 10);
    return .{
        .quota = quota,
        .period = period,
    };
}

pub fn cpu_stat_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !CpuStat {
    var buf: [512]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, cpu_stat, &buf);
    var stat: CpuStat = .{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const key = it.next() orelse continue;
        const val_str = it.next() orelse continue;
        const val = std.fmt.parseInt(u64, val_str, 10) catch continue;
        if (std.mem.eql(u8, key, "usage_usec"))
            stat.usage_usec = val
        else if (std.mem.eql(u8, key, "user_usec"))
            stat.user_usec = val
        else if (std.mem.eql(u8, key, "system_usec"))
            stat.system_usec = val
        else if (std.mem.eql(u8, key, "nr_periods"))
            stat.nr_periods = val
        else if (std.mem.eql(u8, key, "nr_throttled"))
            stat.nr_throttled = val
        else if (std.mem.eql(u8, key, "throttled_usec"))
            stat.throttled_usec = val
        else {}
    }
    return stat;
}

pub fn cpu_weight_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, val: ?u32) !void {
    const write = if (val) |v|
        try gpa.print("{d}", .{v})
    else
        null;
    defer if (write) |w|
        gpa.free(w);
    try _write(gpa, io, self.path, cpu_weight, write orelse "default");
}

pub fn cpu_weight_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !?u32 {
    var buf: [32]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, cpu_weight, &buf);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return if (std.mem.eql(u8, trimmed, "default"))
        null
    else
        try std.fmt.parseInt(u32, trimmed, 10);
}

pub fn io_weight_set(self: @This(), gpa: std.mem.Allocator, io: std.Io, val: ?u32) !void {
    const write = if (val) |v|
        try gpa.print("{d}", .{v})
    else
        null;
    defer if (write) |w|
        gpa.free(w);
    try _write(gpa, io, self.path, io_weight, write orelse "default");
}

pub fn io_weight_get(self: @This(), gpa: std.mem.Allocator, io: std.Io) !?u32 {
    var buf: [32]u8 = undefined;
    const content = try _readbuf(gpa, io, self.path, io_weight, &buf);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    return if (std.mem.startsWith(u8, trimmed, "default")) blk: {
        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        _ = it.next();
        const num = it.next() orelse break :blk null;
        break :blk try std.fmt.parseInt(u32, num, 10);
    } else try std.fmt.parseInt(u32, trimmed, 10);
}
