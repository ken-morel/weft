const std = @import("std");

const Term = @import("../domain/Term.zig");
const format_bytes = @import("../util/sizes.zig").format_bytes;
const Deployment = @import("Deployment.zig");
const DeploymentState = @import("DeploymentState.zig");

gpa: std.mem.Allocator,
term: *Term,
state: *DeploymentState,
deployment_id: Deployment.Id,
step_history: std.StringHashMapUnmanaged(DeploymentState.Step.Status) = .empty,
artifact_history: std.StringHashMapUnmanaged(DeploymentState.Artifact.Status) = .empty,

pub fn init(gpa: std.mem.Allocator, term: *Term, state: *DeploymentState, deployment_id: Deployment.Id) @This() {
    return .{
        .gpa = gpa,
        .term = term,
        .state = state,
        .deployment_id = deployment_id,
        .step_history = .empty,
        .artifact_history = .empty,
    };
}

pub fn deinit(self: *@This()) void {
    self.term.flush() catch {};
    var step_iter = self.step_history.iterator();
    while (step_iter.next()) |entry|
        self.gpa.free(entry.key_ptr.*);

    self.step_history.deinit(self.gpa);

    var art_iter = self.artifact_history.iterator();
    while (art_iter.next()) |entry|
        self.gpa.free(entry.key_ptr.*);

    self.artifact_history.deinit(self.gpa);
}

pub fn print_logs(self: *@This(), prefix: []const u8, content: []const u8) !void {
    try self.term.print_logs(prefix, content);
}

pub fn update(self: *@This(), io: std.Io) !void {
    self.state.mutex.lockUncancelable(io);
    defer self.state.mutex.unlock(io);

    for (self.state.steps.items) |step| {
        const color = Term.task_color(step.pipeline.name);
        const duration_ms: u64 = @intCast(@max(step.started.durationTo(.now(io, .real)).toMilliseconds(), 0));

        const key = try self.gpa.print("{s}.{s}", .{ step.remote.@"0", step.pipeline.name });
        defer self.gpa.free(key);

        if (self.step_history.get(step.pipeline.name)) |prev_status| {
            if (prev_status != step.status) {
                if (step.status == .running and (prev_status == .preparing or prev_status == .initializing))
                    self.term.write_event(color, "{", " {s}", .{key})
                else if (step.status == .completed)
                    self.term.write_event(.green, "}", " {s} ({d}ms, CPU: {d}ms)", .{ key, duration_ms, step.cpu_ms orelse 0 })
                else if (step.status == .err)
                    self.term.write_event(.red, "#.err", " {s} ({d}ms, CPU: {d}ms): {s}", .{ key, duration_ms, step.cpu_ms orelse 0, step.err orelse "<unknown error>" })
                else if (step.status == .skipped)
                    self.term.write_event(.green, "#.skipped", " {s} ({d}ms, CPU: {d}ms)", .{ key, duration_ms, step.cpu_ms orelse 0 })
                else if (step.status == .stopped)
                    self.term.write_event(.red, "#.stopped", " {s} ({d}ms, CPU: {d}ms)", .{ key, duration_ms, step.cpu_ms orelse 0 });

                if (self.step_history.getPtr(step.pipeline.name)) |ptr|
                    ptr.* = step.status;
            }
        } else {
            if (step.status == .running)
                self.term.write_event(color, "{", " {s}", .{key})
            else if (step.status == .completed)
                self.term.write_event(color, "{}", " {s}", .{key})
            else if (step.status == .err)
                self.term.write_event(.red, "{#.err", " {s} {s}", .{ key, step.err orelse "<unknown error>" })
            else if (step.status == .skipped)
                self.term.write_event(.green, "{#.skipped", " {s} ({d}ms, CPU: {d}ms)", .{ key, duration_ms, step.cpu_ms orelse 0 })
            else if (step.status == .stopped)
                self.term.write_event(.red, "{#.stopped", " {s} ({d}ms, CPU: {d}ms)", .{ key, duration_ms, step.cpu_ms orelse 0 });

            try self.step_history.put(self.gpa, try self.gpa.dupe(u8, step.pipeline.name), step.status);
        }
    }

    for (self.state.artifacts.items) |art| {
        const key = try self.gpa.print("{s}@{s}", .{ art.name, art.remote.@"0" });
        defer self.gpa.free(key);

        if (self.artifact_history.get(key)) |prev_status| {
            if (prev_status != art.status) {
                if (art.status == .pulling and prev_status != .pulling) {
                    self.term.write_event(.cyan, "<", " {s}", .{key});
                } else if (art.status == .pushing and prev_status != .pushing) {
                    self.term.write_event(.yellow, ">", " {s}", .{key});
                }
                if (self.artifact_history.getPtr(key)) |ptr|
                    ptr.* = art.status;
            }
        } else {
            if (art.status == .pulling) {
                self.term.write_event(.cyan, "<", " {s}", .{key});
            } else if (art.status == .pushing) {
                self.term.write_event(.yellow, ">", " {s}", .{key});
            }
            try self.artifact_history.put(self.gpa, try self.gpa.dupe(u8, key), art.status);
        }
    }

    if (!self.term.is_tty) {
        try self.term.flush();
        return;
    }

    var lines_count: u16 = 0;

    const has_active_items = for (self.state.steps.items) |step| {
        if (step.status == .preparing or step.status == .initializing or step.status == .running)
            break true;
    } else for (self.state.artifacts.items) |art| {
        if (art.status == .pulling or art.status == .pushing)
            break true;
    } else false;

    if (has_active_items) {
        self.term.clear_line();
        self.term.println("", .{});
        self.term.clear_line();
        self.term.styled_ln(.dim, " [{s}] ", .{&self.deployment_id.to_string()});
        lines_count += 2;

        for (self.state.steps.items) |step| {
            if (step.status == .preparing) {
                self.term.clear_line();
                self.term.styled_ln(.dim, "  {s}.{s}", .{ step.remote.@"0", step.pipeline.name });
                lines_count += 1;
            } else if (step.status == .initializing) {
                self.term.clear_line();
                self.term.styled_ln(.dim, "? {s}.{s}", .{ step.remote.@"0", step.pipeline.name });
                lines_count += 1;
            } else if (step.status == .running) {
                var mem_buf: [32]u8 = undefined;
                const m_str = if (step.memory_bytes) |mb|
                    format_bytes(&mem_buf, mb) catch "..."
                else
                    "--";
                const duration = step.started.durationTo(.now(io, .real)).toMilliseconds();

                const key = try self.gpa.print("{s}.{s}", .{ step.remote.@"0", step.pipeline.name });
                defer self.gpa.free(key);
                const color = Term.task_color(key);
                self.term.clear_line();
                self.term.styled_ln(
                    color,
                    "! {s} ({d}ms, CPU: {d:.1}% / {d}ms, RAM: {s})",
                    .{
                        key,

                        duration,
                        step.cpu_pct orelse 0,
                        step.cpu_ms orelse 0,
                        m_str,
                    },
                );
                lines_count += 1;
            }
        }

        for (self.state.artifacts.items) |art| {
            if (art.status == .pulling) {
                const pct: u32 = @intFromFloat(@max(0.0, @min(100.0, art.percent * 100.0)));
                self.term.clear_line();
                self.term.styled_ln(.cyan, "< .{s}@{s} {d}%", .{ art.name, art.remote.@"0", pct });
                lines_count += 1;
            } else if (art.status == .pushing) {
                const pct: u32 = @intFromFloat(@max(0.0, @min(100.0, art.percent * 100.0)));
                self.term.clear_line();
                self.term.styled_ln(.yellow, "> {s}@{s} {d}%", .{ art.name, art.remote.@"0", pct });
                lines_count += 1;
            }
        }
    }

    if (self.term.is_tty) {
        self.term.clear_to_end();
        if (lines_count > 0)
            self.term.move_up(lines_count);
    }
    try self.term.flush();
}
