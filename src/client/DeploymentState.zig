const std = @import("std");

const Weft = @import("../domain/Weft.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");

pub const Step = struct {
    pub const Status = enum {
        preparing,
        running,
        completed,
        err,
    };
    remote: *const Remote,
    pipeline: *const Weft.Pipeline,
    status: Status,
    err: ?[]const u8 = null,
    cpu_ms: ?u64 = null,
    cpu_pct: ?f32 = null,
    memory_bytes: ?u64 = null,
    prev_cpu_usec: ?u64 = null,
    last_poll_time: ?std.Io.Timestamp = null,
    log_offset: u64 = 0,
};
pub const Artifact = struct {
    pub const Status = enum {
        pulling,
        pushing,
        ready,
    };
    name: []const u8,
    remote: *const Remote,
    percent: f32,
    status: Status,
};

project: *const Project,
alloc: std.mem.Allocator,
steps: std.ArrayList(Step),
artifacts: std.ArrayList(Artifact),
mutex: std.Io.Mutex = .init,

pub fn init(alloc: std.mem.Allocator, project: *const Project) @This() {
    return .{
        .project = project,
        .alloc = alloc,
        .steps = .empty,
        .artifacts = .empty,
    };
}

pub fn deinit(self: *@This()) void {
    for (self.artifacts.items) |a|
        self.alloc.free(a.name);
    self.artifacts.deinit(self.alloc);
    self.steps.deinit(self.alloc);
}

fn get_unlocked(self: *@This(), remote_name: []const u8, pipeline_name: []const u8) ?*Step {
    for (self.steps.items) |*s|
        if (std.mem.eql(u8, s.remote.get_name(), remote_name) and std.mem.eql(u8, s.pipeline.name, pipeline_name))
            return s;

    return null;
}

fn artifact_unlocked(self: *@This(), name: []const u8, remote_name: []const u8) ?*Artifact {
    for (self.artifacts.items) |*a|
        if (std.mem.eql(u8, a.name, name) and std.mem.eql(u8, a.remote.get_name(), remote_name))
            return a;

    return null;
}

pub fn add(self: *@This(), io: std.Io, remote: *const Remote, pipeline: *const Weft.Pipeline) !*Step {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.get_unlocked(remote.get_name(), pipeline.name)) |s|
        return s;

    try self.steps.append(self.alloc, .{
        .remote = remote,
        .pipeline = pipeline,
        .status = .preparing,
        .err = null,
    });
    return &self.steps.items[self.steps.items.len - 1];
}

pub fn get(self: *@This(), io: std.Io, remote_name: []const u8, pipeline_name: []const u8) ?Step {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.get_unlocked(remote_name, pipeline_name)) |s|
        return s.*;

    return null;
}

pub fn running(self: *@This(), io: std.Io, remote_name: []const u8, pipeline_name: []const u8) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.get_unlocked(remote_name, pipeline_name)) |s|
        s.status = .running;
}

pub fn completed(self: *@This(), io: std.Io, remote_name: []const u8, pipeline_name: []const u8) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.get_unlocked(remote_name, pipeline_name)) |s|
        s.status = .completed;
}

pub fn err(self: *@This(), io: std.Io, remote_name: []const u8, pipeline_name: []const u8, err_msg: []const u8) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.get_unlocked(remote_name, pipeline_name)) |s| {
        s.status = .err;
        s.err = err_msg;
    }
}

pub fn update_usage(self: *@This(), io: std.Io, remote_name: []const u8, pipeline_name: []const u8, cpu_usec: u64, memory_bytes: u64, now: std.Io.Timestamp) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.get_unlocked(remote_name, pipeline_name)) |s| {
        s.memory_bytes = memory_bytes;
        s.cpu_ms = cpu_usec / 1000;
        if (s.last_poll_time) |last_t| {
            const dt_ns = now.nanoseconds - last_t.nanoseconds;
            if (dt_ns > 50_000_000 and s.prev_cpu_usec != null) {
                const dt_usec = @divTrunc(dt_ns, 1000);
                const delta_usec = cpu_usec -| s.prev_cpu_usec.?;
                s.cpu_pct = @as(f32, @floatFromInt(delta_usec)) * 100.0 / @as(f32, @floatFromInt(dt_usec));
            }
        }
        s.prev_cpu_usec = cpu_usec;
        s.last_poll_time = now;
    }
}

pub fn set_log_offset(self: *@This(), io: std.Io, remote_name: []const u8, pipeline_name: []const u8, offset: u64) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.get_unlocked(remote_name, pipeline_name)) |s| {
        s.log_offset = offset;
    }
}

pub fn artifact_progress(self: *@This(), io: std.Io, name: []const u8, remote: *const Remote, status: Artifact.Status, percent: f32) !void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    if (self.artifact_unlocked(name, remote.get_name())) |a| {
        a.status = status;
        a.percent = percent;
    } else {
        try self.artifacts.append(self.alloc, .{
            .name = try self.alloc.dupe(u8, name),
            .remote = remote,
            .status = status,
            .percent = percent,
        });
    }
}

pub fn has_error(self: *@This(), io: std.Io) bool {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    for (self.steps.items) |s|
        if (s.status == .err)
            return true;

    return false;
}
