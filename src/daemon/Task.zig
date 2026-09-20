const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const systemd = @import("../util/systemd.zig");

const Task = @This();

id: proto.task.Id,

pub fn from_unit_name(name: []const u8) ?@This() {
    var iter = std.mem.splitSequence(u8, name, "--");
    const runner = iter.next() orelse return null;
    if (!std.mem.eql(u8, runner, "weft-runner"))
        return null;

    const workspace = iter.next() orelse return null;
    const service = iter.next() orelse return null;
    const pipeline = iter.next() orelse return null;
    const deployment_id = iter.next() orelse return null;

    const deployment = Deployment.Id.parse(deployment_id) catch return null;

    return .{ .id = .{
        .workspace = workspace,
        .service = service,
        .deployment = deployment,
        .pipeline = pipeline,
    } };
}

pub fn kill(self: @This(), alloc: std.mem.Allocator, io: std.Io) !void {
    const unit = try self.unit_name(alloc);
    defer alloc.free(unit);
    try systemd.kill(io, unit);
}

pub fn is_active(self: @This(), alloc: std.mem.Allocator, io: std.Io) !bool {
    const unit = try self.unit_name(alloc);
    defer alloc.free(unit);
    return systemd.is_active(io, unit);
}

pub fn unit_name(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
    return try std.mem.join(
        alloc,
        "--",
        &.{
            "weft-runner",
            self.id.workspace,
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
        self.id.pipeline,
        &self.id.deployment.to_string(),
    );
}

pub fn archive(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
    return paths.task_archive(
        alloc,
        self.id.workspace,
        self.id.service,
        &self.id.deployment.to_string(),
        self.id.pipeline,
    );
}

pub fn keep_path(self: @This(), alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    return paths.task_cache(
        alloc,
        self.id.workspace,
        name,
    );
}
pub fn artifacts_path(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
    return try paths.artifacts(
        alloc,

        self.id.workspace,
        self.id.service,
        &self.id.deployment.to_string(),
    );
}

pub const TaskSiblingsIterator = struct {
    task: *const Task,
    walker: ?std.Io.Dir.SelectiveWalker,

    pub fn next(self: *@This(), io: std.Io) !?Task {
        if (self.walker) |*walker| {
            while (true) {
                const task_deployment = self.task.id.deployment.to_string();
                const entry = try walker.next(io) orelse return null;
                var sibling = self.task.*; // copy

                if (std.mem.eql(u8, &task_deployment, entry.basename))
                    continue;
                sibling.id.deployment = try Deployment.Id.parse(entry.basename);
                return sibling;
            }
        } else return null;
    }
};

pub fn siblings(self: *const @This(), alloc: std.mem.Allocator, io: std.Io) !TaskSiblingsIterator {
    const run_dir = try self.run_dir_path(alloc);
    defer alloc.free(run_dir);
    const pipeline_dir = std.fs.path.dirname(run_dir).?;
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

pub fn dupe(self: @This(), alloc: std.mem.Allocator) !@This() {
    return .{
        .id = try self.id.dupe(alloc),
    };
}
pub fn free_duped(self: @This(), alloc: std.mem.Allocator) !void {
    self.id.free_duped(alloc);
}
