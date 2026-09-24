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
    while (step_iter.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
    }
    self.step_history.deinit(self.alloc);

    var art_iter = self.artifact_history.iterator();
    while (art_iter.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
    }
    self.artifact_history.deinit(self.alloc);
}

pub fn print_logs(self: *@This(), prefix: []const u8, content: []const u8) void {
    if (self.term.is_tty and self.rendered_lines > 0) {
        self.term.move_up(self.rendered_lines);
        self.term.clear_to_end();
        self.rendered_lines = 0;
    }

    const is_color = self.term.is_tty;
    const tabs: []const u8 = if (prefix.len < 8) "\t\t" else "\t";

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, content, "\r\n"), '\n');
    var first = true;
    while (lines.next()) |line| {
        const clean_line = std.mem.trimEnd(u8, line, "\r");
        if (first) {
            if (is_color) {
                self.term.println("\x1b[36m{s}\x1b[0m{s}{s}", .{ prefix, tabs, clean_line });
            } else {
                self.term.println("{s}{s}{s}", .{ prefix, tabs, clean_line });
            }
            first = false;
        } else {
            self.term.println("\t|\t{s}", .{clean_line});
        }
    }
    self.term.flush() catch {};
}

pub fn print_log_lines(term: *Term, lock: ?*std.Io.Mutex, io: std.Io, prefix: []const u8, content: []const u8) void {
    if (lock) |m| {
        m.lockUncancelable(io);
    }
    defer if (lock) |m| {
        m.unlock(io);
    };

    const is_color = term.is_tty;
    const tabs: []const u8 = if (prefix.len < 8) "\t\t" else "\t";

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, content, "\r\n"), '\n');
    var first = true;
    while (lines.next()) |line| {
        const clean_line = std.mem.trimEnd(u8, line, "\r");
        if (first) {
            if (is_color) {
                term.println("\x1b[36m{s}\x1b[0m{s}{s}", .{ prefix, tabs, clean_line });
            } else {
                term.println("{s}{s}{s}", .{ prefix, tabs, clean_line });
            }
            first = false;
        } else {
            term.println("\t|\t{s}", .{clean_line});
        }
    }
}

pub fn update(self: *@This(), io: std.Io) !void {
    self.state.mutex.lockUncancelable(io);
    defer self.state.mutex.unlock(io);

    if (self.term.is_tty and self.rendered_lines > 0) {
        self.term.move_up(self.rendered_lines);
        self.rendered_lines = 0;
    }

    const color = self.term.is_tty;

    // 1. Process and print permanent step state transition events
    for (self.state.steps.items) |step| {
        const key = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ step.remote.get_name(), step.pipeline.name });
        defer self.alloc.free(key);

        if (self.step_history.get(key)) |prev_status| {
            if (prev_status != step.status) {
                if (step.status == .running and prev_status == .preparing) {
                    if (color) {
                        self.term.println("\x1b[36mstart\x1b[0m\t\t{s}", .{key});
                    } else {
                        self.term.println("start\t\t{s}", .{key});
                    }
                } else if (step.status == .completed) {
                    if (color) {
                        self.term.println("\x1b[32mdone\x1b[0m\t\t{s}", .{key});
                    } else {
                        self.term.println("done\t\t{s}", .{key});
                    }
                } else if (step.status == .err) {
                    if (color) {
                        self.term.println("\x1b[31merror\x1b[0m\t\t{s}: {s}", .{ key, step.err orelse "<unknown error>" });
                    } else {
                        self.term.println("error\t\t{s}: {s}", .{ key, step.err orelse "<unknown error>" });
                    }
                }
                _ = self.step_history.put(self.alloc, try self.alloc.dupe(u8, key), step.status) catch {};
            }
        } else {
            if (step.status == .running) {
                if (color) {
                    self.term.println("\x1b[36mstart\x1b[0m\t\t{s}", .{key});
                } else {
                    self.term.println("start\t\t{s}", .{key});
                }
            } else if (step.status == .completed) {
                if (color) {
                    self.term.println("\x1b[32mdone\x1b[0m\t\t{s}", .{key});
                } else {
                    self.term.println("done\t\t{s}", .{key});
                }
            } else if (step.status == .err) {
                if (color) {
                    self.term.println("\x1b[31merror\x1b[0m\t\t{s}: {s}", .{ key, step.err orelse "<unknown error>" });
                } else {
                    self.term.println("error\t\t{s}: {s}", .{ key, step.err orelse "<unknown error>" });
                }
            }
            try self.step_history.put(self.alloc, try self.alloc.dupe(u8, key), step.status);
        }
    }

    // 2. Process and print permanent artifact state transition events
    for (self.state.artifacts.items) |art| {
        const key = try std.fmt.allocPrint(self.alloc, "{s}@{s}", .{ art.name, art.remote.get_name() });
        defer self.alloc.free(key);

        if (self.artifact_history.get(key)) |prev_status| {
            if (prev_status != art.status) {
                if (art.status == .pulling) {
                    if (color) {
                        self.term.println("\x1b[33martifact\x1b[0m\t{s} pulling", .{key});
                    } else {
                        self.term.println("artifact\t{s} pulling", .{key});
                    }
                } else if (art.status == .pushing) {
                    if (color) {
                        self.term.println("\x1b[33martifact\x1b[0m\t{s} pushing", .{key});
                    } else {
                        self.term.println("artifact\t{s} pushing", .{key});
                    }
                } else if (art.status == .ready and prev_status == .pulling) {
                    if (color) {
                        self.term.println("\x1b[33martifact\x1b[0m\t{s} pulled", .{key});
                    } else {
                        self.term.println("artifact\t{s} pulled", .{key});
                    }
                } else if (art.status == .ready and prev_status == .pushing) {
                    if (color) {
                        self.term.println("\x1b[33martifact\x1b[0m\t{s} pushed", .{key});
                    } else {
                        self.term.println("artifact\t{s} pushed", .{key});
                    }
                }
                _ = self.artifact_history.put(self.alloc, try self.alloc.dupe(u8, key), art.status) catch {};
            }
        } else {
            if (art.status == .pulling) {
                if (color) {
                    self.term.println("\x1b[33martifact\x1b[0m\t{s} pulling", .{key});
                } else {
                    self.term.println("artifact\t{s} pulling", .{key});
                }
            } else if (art.status == .pushing) {
                if (color) {
                    self.term.println("\x1b[33martifact\x1b[0m\t{s} pushing", .{key});
                } else {
                    self.term.println("artifact\t{s} pushing", .{key});
                }
            } else if (art.status == .ready) {
                if (color) {
                    self.term.println("\x1b[33martifact\x1b[0m\t{s} ready", .{key});
                } else {
                    self.term.println("artifact\t{s} ready", .{key});
                }
            }
            try self.artifact_history.put(self.alloc, try self.alloc.dupe(u8, key), art.status);
        }
    }

    // If non-interactive / non-TTY, skip the pinned bottom bar completely
    if (!self.term.is_tty) {
        try self.term.flush();
        return;
    }

    // 3. Render the interactive pinned bottom deck
    var lines_count: u16 = 0;

    for (self.state.steps.items) |step| {
        if (step.status == .preparing) {
            self.term.clear_line();
            self.term.println("? {s}.{s}", .{ step.remote.get_name(), step.pipeline.name });
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
            self.term.clear_line();
            self.term.println("! {s}.{s}{s}", .{ step.remote.get_name(), step.pipeline.name, stats_str });
            lines_count += 1;
        }
    }

    for (self.state.artifacts.items) |art| {
        if (art.status == .pulling) {
            const pct: u32 = @intFromFloat(@max(0.0, @min(100.0, art.percent * 100.0)));
            self.term.clear_line();
            self.term.println("<< {s}@{s} {d}%", .{ art.name, art.remote.get_name(), pct });
            lines_count += 1;
        } else if (art.status == .pushing) {
            const pct: u32 = @intFromFloat(@max(0.0, @min(100.0, art.percent * 100.0)));
            self.term.clear_line();
            self.term.println(">> {s}@{s} {d}%", .{ art.name, art.remote.get_name(), pct });
            lines_count += 1;
        }
    }

    self.rendered_lines = lines_count;
    self.term.clear_to_end();
    try self.term.flush();
}
