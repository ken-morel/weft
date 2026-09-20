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

pub fn add_step(self: *@This(), remote: *const Remote, pipeline: *const Weft.Pipeline) !*Step {
    for (self.steps.items) |*s|
        if (std.mem.eql(u8, s.remote.get_name(), remote.get_name()) and std.mem.eql(u8, s.pipeline.name, pipeline.name))
            return s;

    try self.steps.append(self.alloc, .{
        .remote = remote,
        .pipeline = pipeline,
        .status = .preparing,
        .err = null,
    });
    return &self.steps.items[self.steps.items.len - 1];
}

pub fn get_step(self: *@This(), remote_name: []const u8, pipeline_name: []const u8) ?*Step {
    for (self.steps.items) |*s|
        if (std.mem.eql(u8, s.remote.get_name(), remote_name) and std.mem.eql(u8, s.pipeline.name, pipeline_name))
            return s;

    return null;
}

pub fn set_step_running(self: *@This(), remote_name: []const u8, pipeline_name: []const u8) void {
    if (self.get_step(remote_name, pipeline_name)) |s|
        s.status = .running;
}

pub fn set_step_completed(self: *@This(), remote_name: []const u8, pipeline_name: []const u8) void {
    if (self.get_step(remote_name, pipeline_name)) |s|
        s.status = .completed;
}

pub fn set_step_err(self: *@This(), remote_name: []const u8, pipeline_name: []const u8, err_msg: []const u8) void {
    if (self.get_step(remote_name, pipeline_name)) |s| {
        s.status = .err;
        s.err = err_msg;
    }
}

pub fn get_artifact(self: *@This(), name: []const u8, remote_name: []const u8) ?*Artifact {
    for (self.artifacts.items) |*a|
        if (std.mem.eql(u8, a.name, name) and std.mem.eql(u8, a.remote.get_name(), remote_name))
            return a;

    return null;
}

pub fn set_artifact_progress(self: *@This(), name: []const u8, remote: *const Remote, status: Artifact.Status, percent: f32) !void {
    if (self.get_artifact(name, remote.get_name())) |a| {
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

pub fn has_error(self: @This()) bool {
    for (self.steps.items) |s|
        if (s.status == .err)
            return true;

    return false;
}
