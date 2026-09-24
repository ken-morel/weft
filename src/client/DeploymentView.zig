const std = @import("std");

const Term = @import("../domain/Term.zig");
const format_bytes = @import("../util/sizes.zig").format_bytes;
const Deployment = @import("Deployment.zig");
const DeploymentState = @import("DeploymentState.zig");

alloc: std.mem.Allocator,
term: *Term,
state: *DeploymentState,
deployment_id: Deployment.Id,
rendered_lines: u16 = 0,
step_history: std.StringHashMapUnmanaged(DeploymentState.Step.Status) = .empty,
artifact_history: std.StringHashMapUnmanaged(DeploymentState.Artifact.Status) = .empty,

pub fn init(alloc: std.mem.Allocator, term: *Term, state: *DeploymentState, deployment_id: Deployment.Id) @This() {
    return .{
        .alloc = alloc,
        .term = term,
        .state = state,
        .deployment_id = deployment_id,
        .rendered_lines = 0,
        .step_history = .empty,
        .artifact_history = .empty,
    };
}

pub fn deinit(self: *@This()) void {
    if (self.term.is_tty and self.rendered_lines > 0) {
        self.term.move_up(self.rendered_lines);
        self.term.clear_to_end();
        self.term.flush() catch {};
        self.rendered_lines = 0;
    }
    var step_iter = self.step_history.iterator();
    while (step_iter.next()) |entry|
        self.alloc.free(entry.key_ptr.*);

    self.step_history.deinit(self.alloc);

    var art_iter = self.artifact_history.iterator();
    while (art_iter.next()) |entry|
        self.alloc.free(entry.key_ptr.*);

    self.artifact_history.deinit(self.alloc);
}

pub fn print_logs(self: *@This(), prefix: []const u8, content: []const u8) void {
    if (self.term.is_tty and self.rendered_lines > 0) {
        self.term.move_up(self.rendered_lines);
        self.term.clear_to_end();
        self.rendered_lines = 0;
    }

    const color = Term.task_color(prefix);
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, content, "\r\n"), '\n');
    while (lines.next()) |line| {
        const clean_line = std.mem.trimEnd(u8, line, "\r");
        self.term.write_task_log(color, prefix, clean_line);
    }
    if (self.term.is_tty)
        self.term.clear_to_end();

    self.term.flush() catch {};
}

pub fn update(self: *@This(), io: std.Io) !void {
    self.state.mutex.lockUncancelable(io);
    defer self.state.mutex.unlock(io);

    if (self.term.is_tty and self.rendered_lines > 0) {
        self.term.move_up(self.rendered_lines);
        self.term.clear_to_end();
        self.rendered_lines = 0;
    }

    for (self.state.steps.items) |step| {
        const key = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ step.remote.get_name(), step.pipeline.name });
        defer self.alloc.free(key);
        const color = Term.task_color(key);

        if (self.step_history.get(key)) |prev_status| {
            if (prev_status != step.status) {
                if (step.status == .running and prev_status == .preparing)
                    self.term.write_event(color, "{", " {s}", .{key})
                else if (step.status == .completed)
                    self.term.write_event(.green, "}", " {s}", .{key})
                else if (step.status == .err)
                    self.term.write_event(.red, "}", " {s} ({s})", .{ key, step.err orelse "<unknown error>" });

                try self.step_history.put(self.alloc, try self.alloc.dupe(u8, key), step.status);
            }
        } else {
            if (step.status == .running) {
                self.term.write_event(color, "{", " {s}", .{key});
            } else if (step.status == .completed) {
                self.term.write_event(color, "{", " {s}", .{key});
                self.term.write_event(.green, "}", " {s}", .{key});
            } else if (step.status == .err) {
                self.term.write_event(color, "{", " {s}", .{key});
                self.term.write_event(.red, "}", " {s} ({s})", .{ key, step.err orelse "<unknown error>" });
            }
            try self.step_history.put(self.alloc, try self.alloc.dupe(u8, key), step.status);
        }
    }

    for (self.state.artifacts.items) |art| {
        const key = try std.fmt.allocPrint(self.alloc, "{s}@{s}", .{ art.name, art.remote.get_name() });
        defer self.alloc.free(key);

        if (self.artifact_history.get(key)) |prev_status| {
            if (prev_status != art.status) {
                if (art.status == .pulling and prev_status != .pulling) {
                    self.term.write_event(.cyan, "<", " {s}", .{key});
                } else if (art.status == .pushing and prev_status != .pushing) {
                    self.term.write_event(.yellow, ">", " {s}", .{key});
                }
                _ = self.artifact_history.put(self.alloc, try self.alloc.dupe(u8, key), art.status) catch {};
            }
        } else {
            if (art.status == .pulling) {
                self.term.write_event(.cyan, "<", " {s}", .{key});
            } else if (art.status == .pushing) {
                self.term.write_event(.yellow, ">", " {s}", .{key});
            }
            try self.artifact_history.put(self.alloc, try self.alloc.dupe(u8, key), art.status);
        }
    }

    if (!self.term.is_tty) {
        try self.term.flush();
        return;
    }

    var lines_count: u16 = 0;

    var has_active_items = false;
    for (self.state.steps.items) |step| {
        if (step.status == .preparing or step.status == .running) {
            has_active_items = true;
            break;
        }
    }
    if (!has_active_items) {
        for (self.state.artifacts.items) |art| {
            if (art.status == .pulling or art.status == .pushing) {
                has_active_items = true;
                break;
            }
        }
    }

    if (has_active_items) {
        const term_size = self.term.get_size();
        const width: usize = @min(@as(usize, term_size.cols), 60);
        var rule_buf: [256]u8 = undefined;
        const char = "─";
        const count = @max(width, 10);
        var pos: usize = 0;
        for (0..count) |_| {
            if (pos + char.len <= rule_buf.len) {
                @memcpy(rule_buf[pos .. pos + char.len], char);
                pos += char.len;
            }
        }
        self.term.clear_line();
        self.term.styled_ln(.dim, "{s}", .{rule_buf[0..pos]});
        lines_count += 1;

        for (self.state.steps.items) |step| {
            if (step.status == .preparing) {
                self.term.clear_line();
                self.term.styled_ln(.dim, "? {s}.{s}", .{ step.remote.get_name(), step.pipeline.name });
                lines_count += 1;
            } else if (step.status == .running) {
                var stats_buf: [128]u8 = undefined;
                var stats_str: []const u8 = "";
                if (step.cpu_ms != null or step.memory_bytes != null) {
                    var mem_buf: [32]u8 = undefined;
                    const m_str = if (step.memory_bytes) |mb| format_bytes(&mem_buf, mb) else "--";
                    if (step.cpu_pct) |pct| {
                        stats_str = std.fmt.bufPrint(&stats_buf, " (CPU: {d:.1}% / {d}ms, RAM: {s})", .{
                            pct,
                            step.cpu_ms orelse 0,
                            m_str,
                        }) catch "";
                    } else {
                        stats_str = std.fmt.bufPrint(&stats_buf, " (CPU: {d}ms, RAM: {s})", .{
                            step.cpu_ms orelse 0,
                            m_str,
                        }) catch "";
                    }
                }
                const key = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ step.remote.get_name(), step.pipeline.name });
                defer self.alloc.free(key);
                const color = Term.task_color(key);
                self.term.clear_line();
                self.term.styled_ln(color, "! {s}{s}", .{ key, stats_str });
                lines_count += 1;
            }
        }

        for (self.state.artifacts.items) |art| {
            if (art.status == .pulling) {
                const pct: u32 = @intFromFloat(@max(0.0, @min(100.0, art.percent * 100.0)));
                self.term.clear_line();
                self.term.styled_ln(.cyan, "< {s}@{s} {d}%", .{ art.name, art.remote.get_name(), pct });
                lines_count += 1;
            } else if (art.status == .pushing) {
                const pct: u32 = @intFromFloat(@max(0.0, @min(100.0, art.percent * 100.0)));
                self.term.clear_line();
                self.term.styled_ln(.yellow, "> {s}@{s} {d}%", .{ art.name, art.remote.get_name(), pct });
                lines_count += 1;
            }
        }
    }

    self.rendered_lines = lines_count;
    self.term.clear_to_end();
    try self.term.flush();
}
