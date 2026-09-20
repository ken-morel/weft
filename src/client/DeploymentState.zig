const std = @import("std");

const Weft = @import("../domain/Weft.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");

const Step = struct {
    const Status = enum {
        preparing,
        running,
        completed,
        err,
    };
    err: struct { anyerror, []const u8 },
    remote: *const Remote,
    pipeline: *const Weft.Pipeline,
    status: Status,
};
const Artifact = struct {
    percent: f32,
    remote: *const Remote,
};

project: *Project,
alloc: std.mem.Allocator,
steps: std.ArrayList(Step),
artifacts: std.ArrayList(Artifact),

pub fn init(alloc: std.mem.Allocator, project: *Project) @This() {
    return .{
        .project = project,
        .alloc = alloc,
        .steps = .empty,
        .artifacts = .empty,
    };
}
// add, err, done, ...
pub fn render(self: *@This()) !void {
    _ = self;
    // will do myself
}
