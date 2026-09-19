const std = @import("std");

const Deployment = @import("Deployment.zig");
const Remote = @import("Remote.zig");

const StepStatus = union(enum) {
    spawning,
    running: []u8,
    done,
    failed: u16,
};
const Step = struct {
    remote: *const Remote,
    pipeline: []const u8,
    status: StepStatus,
};

alloc: std.mem.Allocator,
steps: std.ArrayList(Step),
deployment: *Deployment,

pub fn spawn(self: *@This(), remote: *const Remote, pipeline: []const u8) !void {
    try self.steps.append(self.alloc, .{
        .remote = remote,
        .pipeline = try self.alloc.dupe(pipeline),
    });
}
pub fn get(self: *@This(), remote: []const u8, pipeline: []const u8) ?*Step {
    for (self.steps.items) |*step| {
        if (std.mem.eql(u8, step.remote.name, remote) and std.mem.eql(u8, step.pipeline, pipeline))
            return step;
    } else return null;
}
pub fn logs(self: *@This(), remote: []const u8, pipeline: []const u8, log: []const u8) !void {
    const step = self.get(remote, pipeline) orelse return error.StepNotFound;

    switch (step.status) {
        .running => |txt| self.alloc.free(txt),
        else => {},
    }
    step.status = .{ .running = try self.alloc.dupe(log) };
}
pub fn done(self: *@This(), remote: []const u8, pipeline: []const u8, status: ?u16) !void {
    const step = self.get(remote, pipeline) orelse return error.StepNotFound;
    switch (step.status) {
        .running => |txt| self.alloc.free(txt),
        else => {},
    }
    if (status) |code|
        step.status = .{ .failed = code }
    else
        step.status = .done;
}

pub fn init(deployment: *Deployment) !@This() {
    return .{ .deployment = deployment };
}
