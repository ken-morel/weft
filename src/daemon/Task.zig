const std = @import("std");

const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const systemd = @import("../util/systemd.zig");

const Task = @This();

id: proto.task.Id,

pub fn kill(self: @This(), alloc: std.mem.Allocator, io: std.Io) !void {
    const unit = try self.unit_name(alloc);
    defer alloc.free(unit);
    try systemd.kill(io, unit);
}

pub fn unit_name(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
    return try std.mem.join(
        alloc,
        "--",
        &.{
            "weft-runner",
            self.id.workspace,
            self.id.env,
            self.id.service,
            self.id.pipeline,
            &self.id.deployment.to_string(),
        },
    );
}

pub fn run_dir_path(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
    return try paths.run(
        alloc,
        self.id.workspace,
        self.id.service,
        self.id.env,
        &self.id.deployment.to_string(),
        self.id.pipeline,
    );
}

pub fn log_path(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
    return paths.task_log(
        alloc,
        self.id.workspace,
        self.id.service,
        self.id.env,
        &self.id.deployment.to_string(),
        self.id.pipeline,
    );
}

pub const TaskSiblingsIterator = struct {
    task: *const Task,
    walker: ?std.Io.Dir.SelectiveWalker,

    pub fn next(self: @This(), io: std.Io) ?Task {
        while (true) {
            const task_deployment = self.task.id.deployment.to_string();
            const walker = &(self.walker orelse return null);
            const entry = try walker.next(io) orelse return null;
            var sibling = self.task.*;

            if (std.mem.eql(u8, &task_deployment, entry.basename))
                continue;
            sibling.id.deployment = try .parse(entry.basename);
            return sibling;
        }
    }
};

pub fn siblings(self: *const @This(), alloc: std.mem.Allocator, io: std.Io) !TaskSiblingsIterator {
    const run_dir = try self.run_dir_path(alloc);
    defer alloc.free(run_dir);
    const pipeline_dir = std.fs.path.dirname(run_dir) orelse error.Unreachable;
    const dir = try std.Io.Dir.cwd().openDir(io, pipeline_dir, .{ .iterate = true });
    const walker: ?std.Io.Dir.SelectiveWalker = std.Io.Dir.walkSelectively(dir, alloc) catch |err|
        if (err == error.FileNotFound)
            null
        else
            return err;

    return .{
        .task = self,
        .walker = walker,
    };
}

pub fn dupe(self: @This(), alloc: std.mem.Allocator) !void {
    return .{
        .id = try self.id.dupe(alloc),
    };
}
