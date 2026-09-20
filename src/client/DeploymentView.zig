const std = @import("std");

const Deployment = @import("Deployment.zig");
const DeploymentState = @import("DeploymentState.zig");
const Term = @import("../domain/Term.zig");

alloc: std.mem.Allocator,
term: *Term,
state: *DeploymentState,
deployment_id: Deployment.Id,
rendered_lines: u16 = 0,
finalized: std.ArrayList([]const u8),
tick: u32 = 0,

pub fn init(alloc: std.mem.Allocator, term: *Term, state: *DeploymentState, deployment_id: Deployment.Id) @This() {
    return .{
        .alloc = alloc,
        .term = term,
        .state = state,
        .deployment_id = deployment_id,
        .rendered_lines = 0,
        .finalized = .empty,
        .tick = 0,
    };
}

pub fn deinit(self: *@This()) void {
    for (self.finalized.items) |k|
        self.alloc.free(k);
    self.finalized.deinit(self.alloc);
}

fn is_finalized(self: *const @This(), key: []const u8) bool {
    for (self.finalized.items) |item|
        if (std.mem.eql(u8, item, key))
            return true;

    return false;
}

fn mark_finalized(self: *@This(), key: []const u8) !void {
    try self.finalized.append(self.alloc, try self.alloc.dupe(u8, key));
}

fn print_log_tail(self: *@This(), io: std.Io, pipeline_name: []const u8, max_lines: usize, cols: u16) u16 {
    const log_path = self.state.project.task_log_path(self.alloc, io, self.deployment_id, pipeline_name) catch return 0;
    defer self.alloc.free(log_path);

    const file = std.Io.Dir.cwd().openFile(io, log_path, .{ .mode = .read_only }) catch return 0;
    defer file.close(io);

    const size = file.length(io) catch return 0;
    if (size == 0)
        return 0;

    const read_size = @min(size, 4096);
    const offset = size - read_size;
    var buf: [4096]u8 = undefined;
    _ = file.readPositionalAll(io, buf[0..read_size], offset) catch return 0;
    const content = buf[0..read_size];

    var lines: [5][]const u8 = undefined;
    var count: usize = 0;
    var slice = std.mem.trimEnd(u8, content, "\r\n");
    while (slice.len > 0 and count < max_lines and count < 5) {
        if (std.mem.lastIndexOfScalar(u8, slice, '\n')) |idx| {
            lines[count] = slice[idx + 1 ..];
            count += 1;
            slice = std.mem.trimEnd(u8, slice[0..idx], "\r");
        } else {
            lines[count] = slice;
            count += 1;
            break;
        }
    }

    const prefix = "   | ";
    const col_limit = if (cols > prefix.len) cols - prefix.len else 0;
    var printed: u16 = 0;
    var i = count;
    while (i > 0) {
        i -= 1;
        var line = std.mem.trimEnd(u8, lines[i], "\r");
        if (line.len > col_limit)
            line = line[0..col_limit];
        self.term.println("{s}{s}", .{ prefix, line });
        printed += 1;
    }
    return printed;
}

fn print_truncated(self: *@This(), cols: u16, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const limit = if (cols > 0) @min(text.len, @as(usize, cols)) else text.len;
    self.term.println("{s}", .{text[0..limit]});
}

pub fn update(self: *@This(), io: std.Io) !void {
    if (!self.term.is_tty()) {
        for (self.state.steps.items) |step| {
            const key = try std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ step.remote.get_name(), step.pipeline.name });
            defer self.alloc.free(key);
            if (self.is_finalized(key))
                continue;

            if (step.status == .completed) {
                self.term.println("ok: [{s}] {s}", .{ step.remote.get_name(), step.pipeline.name });
                try self.mark_finalized(key);
            } else if (step.status == .err) {
                self.term.println("error: [{s}] {s}: {s}", .{ step.remote.get_name(), step.pipeline.name, step.err orelse "failed" });
                try self.mark_finalized(key);
            }
        }
        return;
    }

    if (self.rendered_lines > 0) {
        self.term.move_up(self.rendered_lines);
        self.term.clear_to_end();
        self.rendered_lines = 0;
    }

    for (self.state.steps.items) |step| {
        const key = try std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ step.remote.get_name(), step.pipeline.name });
        defer self.alloc.free(key);
        if (self.is_finalized(key))
            continue;

        if (step.status == .completed) {
            self.term.println("ok: [{s}] {s}", .{ step.remote.get_name(), step.pipeline.name });
            try self.mark_finalized(key);
        } else if (step.status == .err) {
            self.term.println("error: [{s}] {s}: {s}", .{ step.remote.get_name(), step.pipeline.name, step.err orelse "failed" });
            try self.mark_finalized(key);
        }
    }

    const term_size = self.term.get_size();
    var running_count: usize = 0;
    var active_art_count: usize = 0;

    for (self.state.steps.items) |step| {
        if (step.status == .running or step.status == .preparing)
            running_count += 1;
    }

    for (self.state.artifacts.items) |art| {
        if (art.status == .pulling or art.status == .pushing)
            active_art_count += 1;
    }

    const max_screen_lines = if (term_size.rows > 6) term_size.rows - 4 else 4;
    const base_needed = running_count + active_art_count;
    const available_for_logs = if (max_screen_lines > base_needed) max_screen_lines - base_needed else 0;
    const per_task_logs = if (running_count > 0) @min(5, available_for_logs / running_count) else 0;

    var lines_count: u16 = 0;
    self.tick +%= 1;

    for (self.state.steps.items) |step| {
        if (step.status == .preparing) {
            self.print_truncated(term_size.cols, "[wait   ] [{s}] {s}", .{ step.remote.get_name(), step.pipeline.name });
            lines_count += 1;
        } else if (step.status == .running) {
            self.print_truncated(term_size.cols, "[running] [{s}] {s}", .{ step.remote.get_name(), step.pipeline.name });
            lines_count += 1;
            const log_lines = self.print_log_tail(io, step.pipeline.name, per_task_logs, term_size.cols);
            lines_count += log_lines;
        }
    }

    for (self.state.artifacts.items) |art| {
        if (art.status == .pulling) {
            const pct: u32 = @intFromFloat(@max(0.0, @min(100.0, art.percent * 100.0)));
            self.print_truncated(term_size.cols, "[<< pull] [{s}] {s} ({d}%)", .{ art.remote.get_name(), art.name, pct });
            lines_count += 1;
        } else if (art.status == .pushing) {
            const pct: u32 = @intFromFloat(@max(0.0, @min(100.0, art.percent * 100.0)));
            self.print_truncated(term_size.cols, "[>> push] [{s}] {s} ({d}%)", .{ art.remote.get_name(), art.name, pct });
            lines_count += 1;
        }
    }

    self.rendered_lines = lines_count;
    try self.term.flush();
}

pub fn finish(self: *@This(), io: std.Io) !void {
    _ = io;
    if (self.term.is_tty() and self.rendered_lines > 0) {
        self.term.move_up(self.rendered_lines);
        self.term.clear_to_end();
        self.rendered_lines = 0;
    }

    for (self.state.steps.items) |step| {
        const key = try std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ step.remote.get_name(), step.pipeline.name });
        defer self.alloc.free(key);
        if (self.is_finalized(key))
            continue;

        if (step.status == .completed) {
            self.term.println("ok: [{s}] {s}", .{ step.remote.get_name(), step.pipeline.name });
            try self.mark_finalized(key);
        } else if (step.status == .err) {
            self.term.println("error: [{s}] {s}: {s}", .{ step.remote.get_name(), step.pipeline.name, step.err orelse "failed" });
            try self.mark_finalized(key);
        }
    }
    try self.term.flush();
}
