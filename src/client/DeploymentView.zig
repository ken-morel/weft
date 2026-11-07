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

fn render_step(self: *@This(), step: DeploymentState.Step, key: []const u8, duration_ms: u64, prev: ?DeploymentState.Step.Status) void {
    const color = Term.task_color(key);
    switch (step.status) {
        .running => if (prev == null or prev.? == .preparing or prev.? == .initializing)
            self.term.write_event(color, "{", " {s}", .{key}),
        .completed => if (prev == null)
            self.term.write_event(color, "{}", " {s}", .{key})
        else
            self.term.write_event(.green, "}", " {s} ({d}ms, CPU: {d}ms)", .{ key, duration_ms, step.cpu_ms orelse 0 }),
        .err => if (prev == null)
            self.term.write_event(.red, "{#.err", " {s} {s}", .{ key, step.err orelse "<unknown error>" })
        else
            self.term.write_event(.red, "#.err", " {s} ({d}ms, CPU: {d}ms): {s}", .{ key, duration_ms, step.cpu_ms orelse 0, step.err orelse "<unknown error>" }),
        .skipped => self.term.write_event(
            .green,
            if (prev == null) "{#.skipped" else "#.skipped",
            " {s} ({d}ms, CPU: {d}ms)",
            .{ key, duration_ms, step.cpu_ms orelse 0 },
        ),
        .stopped => self.term.write_event(
            .red,
            if (prev == null) "{#.stopped" else "#.stopped",
            " {s} ({d}ms, CPU: {d}ms)",
            .{ key, duration_ms, step.cpu_ms orelse 0 },
        ),
        .preparing, .initializing => {},
    }
}

pub fn update(self: *@This(), io: std.Io) !void {
    self.state.mutex.lockUncancelable(io);
    defer self.state.mutex.unlock(io);

    for (self.state.steps.items) |step| {
        const key = try self.gpa.print("{s}.{s}", .{ step.remote.@"0", step.pipeline.name });
        defer self.gpa.free(key);
        const duration_ms: u64 = @intCast(@max(step.started.durationTo(.now(io, .real)).toMilliseconds(), 0));

        const prev = self.step_history.get(key);
        if (prev != null and prev.? == step.status)
            continue;

        self.render_step(step, key, duration_ms, prev);

        if (prev == null)
            try self.step_history.put(self.gpa, try self.gpa.dupe(u8, key), step.status)
        else if (self.step_history.getPtr(key)) |ptr|
            ptr.* = step.status;
    }

    for (self.state.artifacts.items) |art| {
        const key = try self.gpa.print("{s}@{s}", .{ art.name, art.remote.@"0" });
        defer self.gpa.free(key);

        const prev = self.artifact_history.get(key);
        if (prev != null and prev.? == art.status)
            continue;

        if (art.status == .pulling)
            self.term.write_event(.cyan, "<", " {s}", .{key})
        else if (art.status == .pushing)
            self.term.write_event(.yellow, ">", " {s}", .{key});

        if (prev == null)
            try self.artifact_history.put(self.gpa, try self.gpa.dupe(u8, key), art.status)
        else if (self.artifact_history.getPtr(key)) |ptr|
            ptr.* = art.status;
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
