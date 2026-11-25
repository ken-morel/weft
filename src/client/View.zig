const std = @import("std");
const root = @import("root");

const Task = @import("../domain/Task.zig");
const Term = @import("../domain/Term.zig");
const sizes = @import("../util/sizes.zig");

pub const TaskItem = struct {
    remote: []const u8,
    pipeline: []const u8,
    mode: []const u8,
    status: Task.Status = .preparing,
    reported: ?Task.Status = null,
    err: ?[]const u8 = null,
    cpu_ms: ?u64 = null,
    cpu_pct: ?f32 = null,
    memory_bytes: ?u64 = null,
    prev_cpu_usec: ?u64 = null,
    last_poll_time: ?std.Io.Timestamp = null,
    started: std.Io.Timestamp,
    log_offset: u64 = 0,

    pub fn is_active(self: @This()) bool {
        return switch (self.status) {
            .preparing, .running, .harvesting, .frozen => true,
            .done, .skipped, .failed, .killed, .not_found => false,
        };
    }
};

pub const TransferItem = struct {
    pub const Status = enum { pulling, pushing, ready };
    name: []const u8,
    remote: []const u8,
    percent: f32 = 0,
    status: Status,
    compress: ?bool,
    reported: ?Status = null,
    total: u64,
    speed: u64,
};

pub const TaskPatch = struct {
    status: ?Task.Status = null,
    err: ?[]const u8 = null,
    log_offset: ?u64 = null,
    usage: ?struct {
        cpu_usec: u64,
        memory_bytes: u64,
        now: std.Io.Timestamp,
    } = null,
};

gpa: std.mem.Allocator,
term: *Term,
header: ?[]const u8 = null,
auto_update: bool = true,
tasks: std.ArrayList(TaskItem) = .empty,
transfers: std.ArrayList(TransferItem) = .empty,
mutex: std.Io.Mutex = .init,
render_mutex: std.Io.Mutex = .init,
dirty: std.atomic.Value(bool) = .init(false),
prev_log_level: ?u8 = null,

pub fn init(gpa: std.mem.Allocator, term: *Term, header: ?[]const u8) @This() {
    var prev_log_level: ?u8 = null;
    if (term.is_tty and @hasDecl(root, "log_level")) {
        const info_lvl = @backingInt(std.log.Level.info);
        if (root.log_level.load(.monotonic) > info_lvl) {
            prev_log_level = root.log_level.swap(info_lvl, .monotonic);
        }
    }
    return .{
        .gpa = gpa,
        .term = term,
        .header = header,
        .prev_log_level = prev_log_level,
    };
}

pub fn deinit(self: *@This()) void {
    if (self.prev_log_level) |prev| {
        if (@hasDecl(root, "log_level"))
            root.log_level.store(prev, .monotonic);
    }
    self.term.flush() catch {};
    for (self.tasks.items) |t| {
        self.gpa.free(t.remote);
        self.gpa.free(t.pipeline);
        if (t.err) |e|
            self.gpa.free(e);
    }
    self.tasks.deinit(self.gpa);
    for (self.transfers.items) |a| {
        self.gpa.free(a.name);
        self.gpa.free(a.remote);
    }
    self.transfers.deinit(self.gpa);
}

fn find_task(self: *@This(), remote: []const u8, pipeline: []const u8) ?*TaskItem {
    return for (self.tasks.items) |*t| {
        if (std.mem.eql(u8, t.remote, remote) and std.mem.eql(u8, t.pipeline, pipeline))
            break t;
    } else null;
}

pub fn get_task(self: *@This(), io: std.Io, remote: []const u8, pipeline: []const u8) ?TaskItem {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    return if (self.find_task(remote, pipeline)) |t|
        t.*
    else
        null;
}

pub fn set_task(self: *@This(), io: std.Io, remote: []const u8, pipeline: []const u8, mode: []const u8, patch: TaskPatch) !void {
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var task = self.find_task(remote, pipeline);
        if (task == null) {
            try self.tasks.append(self.gpa, .{
                .remote = try self.gpa.dupe(u8, remote),
                .pipeline = try self.gpa.dupe(u8, pipeline),
                .mode = try self.gpa.dupe(u8, mode),
                .status = patch.status orelse .preparing,
                .started = .now(io, .real),
            });
            task = &self.tasks.items[self.tasks.items.len - 1];
        }
        const t = task.?;

        if (patch.status) |s| {
            const can_update = switch (t.status) {
                .done, .failed, .killed, .skipped => false,
                else => true,
            };
            if (can_update) {
                if (t.status == .preparing and s == .running)
                    t.started = .now(io, .real);
                t.status = s;
            }
        }

        if (patch.err) |e| {
            if (t.err) |old|
                self.gpa.free(old);
            t.err = try self.gpa.dupe(u8, e);
        }

        if (patch.log_offset) |offset|
            t.log_offset = offset;

        if (patch.usage) |u| {
            t.memory_bytes = u.memory_bytes;
            t.cpu_ms = u.cpu_usec / 1000;
            if (t.last_poll_time) |last_t| {
                const dt_ns = u.now.nanoseconds - last_t.nanoseconds;
                if (dt_ns > 50_000_000 and t.prev_cpu_usec != null) {
                    const dt_usec = @divTrunc(dt_ns, 1000);
                    const delta_usec = u.cpu_usec -| (t.prev_cpu_usec orelse 0);
                    t.cpu_pct = @as(f32, @floatFromInt(delta_usec)) * 100.0 / @as(f32, @floatFromInt(dt_usec));
                }
            }
            t.prev_cpu_usec = u.cpu_usec;
            t.last_poll_time = u.now;
        }
    }

    self.dirty.store(true, .release);
    if (self.auto_update)
        try self.try_update(io);
}

pub fn has_error(self: *@This(), io: std.Io) bool {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    return for (self.tasks.items) |t| {
        if (t.status == .failed or t.status == .killed)
            break true;
    } else false;
}

pub fn set_transfer(self: *@This(), io: std.Io, name: []const u8, remote: []const u8, compress: ?bool, status: TransferItem.Status, percent: f32, total: ?u64, speed: ?u64) !void {
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const art: ?*TransferItem = for (self.transfers.items) |*a| {
            if (std.mem.eql(u8, a.name, name) and std.mem.eql(u8, a.remote, remote))
                break a;
        } else null;

        if (art) |a| {
            a.status = status;
            a.percent = percent;
            a.compress = compress orelse a.compress;
            a.total = total orelse a.total;
            a.speed = speed orelse a.speed;
        } else {
            try self.transfers.append(self.gpa, .{
                .compress = compress,
                .name = try self.gpa.dupe(u8, name),
                .remote = try self.gpa.dupe(u8, remote),
                .status = status,
                .percent = percent,
                .total = total orelse 0,
                .speed = speed orelse 0,
            });
        }
    }

    self.dirty.store(true, .release);
    if (self.auto_update)
        try self.try_update(io);
}

pub fn is_transfers_idle(self: *@This(), io: std.Io) bool {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    return for (self.transfers.items) |a| {
        if (a.status == .pulling or a.status == .pushing)
            break false;
    } else true;
}

pub fn print_logs(self: *@This(), prefix: []const u8, content: []const u8) !void {
    const io = self.term.io;
    self.render_mutex.lockUncancelable(io);
    defer self.render_mutex.unlock(io);

    self.term.clear_to_end();
    try self.term.print_logs(prefix, content);
    if (self.auto_update) {
        self.dirty.store(true, .release);
        try self.render_dirty(io);
    }
}

/// Non-blocking render trigger used by auto-updating setters.
pub fn try_update(self: *@This(), io: std.Io) !void {
    while (self.dirty.load(.acquire)) {
        if (!self.render_mutex.tryLock())
            return;
        errdefer self.render_mutex.unlock(io);
        try self.render_dirty(io);
        self.render_mutex.unlock(io);
    }
}

pub fn update(self: *@This(), io: std.Io) !void {
    self.dirty.store(true, .release);
    self.render_mutex.lockUncancelable(io);
    defer self.render_mutex.unlock(io);
    try self.render_dirty(io);
}

fn render_dirty(self: *@This(), io: std.Io) !void {
    while (self.dirty.swap(false, .acq_rel)) {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.render_unlocked(io);
    }
}

fn render_unlocked(self: *@This(), io: std.Io) !void {
    for (self.tasks.items) |*t| {
        if (t.reported) |r|
            if (r.eq(t.status))
                continue;

        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}.{s}", .{ t.mode, t.remote, t.pipeline }) catch t.pipeline;
        const color = Term.task_color(key);
        const duration_ms: u64 = @intCast(@max(t.started.durationTo(.now(io, .real)).toMilliseconds(), 0));

        switch (t.status) {
            .running => if (t.reported == null or t.reported.? == .preparing)
                self.term.write_event(color, "{", " {s}", .{key}),
            .done => if (t.reported == null)
                self.term.write_event(color, "{}", " {s}", .{key})
            else
                self.term.write_event(.green, "}", " {s} ({d}ms, CPU: {d}ms)", .{ key, duration_ms, t.cpu_ms orelse 0 }),
            .failed => if (t.reported == null)
                self.term.write_event(.red, "{#.err", " {s} {s}", .{ key, t.err orelse "<unknown error>" })
            else
                self.term.write_event(.red, "#.err", " {s} ({d}ms, CPU: {d}ms): {s}", .{ key, duration_ms, t.cpu_ms orelse 0, t.err orelse "<unknown error>" }),
            .skipped => self.term.write_event(.green, if (t.reported == null)
                "{}.skipped"
            else
                "}.skipped", " {s} ({d}ms, CPU: {d}ms)", .{ key, duration_ms, t.cpu_ms orelse 0 }),
            .killed => self.term.write_event(.red, if (t.reported == null)
                "{}#killed"
            else
                "}#killed", " {s} ({d}ms, CPU: {d}ms)", .{ key, duration_ms, t.cpu_ms orelse 0 }),
            .not_found => self.term.write_event(color, "#not_found", " {s}", .{key}),
            .preparing, .harvesting, .frozen => {},
        }
        t.reported = t.status;
    }

    for (self.transfers.items) |*a| {
        if (a.reported != null and a.reported.? == a.status)
            continue;
        if (a.compress == null and (a.status == .pulling or a.status == .pushing))
            continue;

        const comp = compressed_ui(a.compress);
        if (a.status == .pulling)
            self.term.write_event(.cyan, "<", " {s}@{s}{s}", .{ a.name, a.remote, comp })
        else if (a.status == .pushing)
            self.term.write_event(.yellow, ">", " {s}@{s}{s}", .{ a.name, a.remote, comp });

        a.reported = a.status;
    }

    if (!self.term.is_tty) {
        try self.term.flush();
        return;
    }

    const has_active = for (self.tasks.items) |t| {
        if (t.is_active())
            break true;
    } else for (self.transfers.items) |a| {
        if (a.status == .pulling or a.status == .pushing)
            break true;
    } else false;

    var lines: u16 = 0;
    if (has_active) {
        self.term.clear_line();
        self.term.println("", .{});
        lines += 1;
        if (self.header) |h| {
            self.term.clear_line();
            self.term.styled_ln(.dim, " [{s}] ", .{h});
            lines += 1;
        }

        for (self.tasks.items) |t| {
            if (!t.is_active())
                continue;
            self.term.clear_line();
            lines += 1;

            var key_buf: [128]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{s}:{s}.{s}", .{ t.mode, t.remote, t.pipeline }) catch t.pipeline;

            switch (t.status) {
                .preparing => self.term.styled_ln(.dim, "  {s}", .{key}),
                .running => {
                    var mem_buf: [32]u8 = undefined;
                    const m_str = if (t.memory_bytes) |mb|
                        sizes.format_bytes(&mem_buf, mb) catch "..."
                    else
                        "--";
                    const dur = t.started.durationTo(.now(io, .real)).toMilliseconds();
                    self.term.styled_ln(
                        Term.task_color(key),
                        "! {s} ({d}ms, CPU: {d:.1}% / {d}ms, RAM: {s})",
                        .{ key, dur, t.cpu_pct orelse 0, t.cpu_ms orelse 0, m_str },
                    );
                },
                .harvesting => {
                    var mem_buf: [32]u8 = undefined;
                    const m_str = if (t.memory_bytes) |mb|
                        sizes.format_bytes(&mem_buf, mb) catch "..."
                    else
                        "--";
                    const dur = t.started.durationTo(.now(io, .real)).toMilliseconds();
                    self.term.styled_ln(
                        Term.task_color(key),
                        "~ {s} (harvesting, {d}ms, CPU: {d}ms, RAM: {s})",
                        .{ key, dur, t.cpu_ms orelse 0, m_str },
                    );
                },
                .frozen => self.term.styled_ln(.dim, "* {s} (frozen)", .{key}),
                else => {},
            }
        }

        for (self.transfers.items) |a| {
            if (a.status == .ready)
                continue;
            self.term.clear_line();
            lines += 1;
            const pct: u32 = @intFromFloat(@max(0.0, @min(100.0, a.percent * 100.0)));
            const comp = compressed_ui(a.compress);
            var total_buf: [1 << 5]u8 = undefined;
            var speed_buf: [1 << 5]u8 = undefined;
            const total = try sizes.format_bytes(&total_buf, a.total);
            const speed = try sizes.format_speed_bytes(&speed_buf, a.speed);

            if (a.status == .pulling)
                self.term.styled_ln(.cyan, "< .{s}@{s}{s} {s}~{d}% @{s}", .{ a.name, a.remote, comp, total, pct, speed })
            else if (a.status == .pushing)
                self.term.styled_ln(.yellow, "> {s}@{s}{s} {s}~{d}% @{s}", .{ a.name, a.remote, comp, total, pct, speed });
        }
    }

    self.term.clear_to_end();
    if (lines > 0)
        self.term.move_up(lines);
    try self.term.flush();
}

pub inline fn compressed_ui(compress: ?bool) []const u8 {
    return if (compress) |c|
        if (c)
            "(compressed)"
        else
            "(not compressed)"
    else
        "(unknown)";
}
