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
    const pipeline = iter.next() orelse return null;
    const deployment_id = iter.next() orelse return null;

    const deployment = Deployment.Id.parse(deployment_id) catch return null;

    return .{ .id = .{
        .workspace = workspace,
        .deployment = deployment,
        .pipeline = pipeline,
    } };
}

pub fn argz_parse(_: std.mem.Allocator, _: ?std.Io, val: []const u8) anyerror!@This() {
    return from_unit_name(val) orelse error.InvalidTask;
}

pub fn kill(self: @This(), alloc: std.mem.Allocator, io: std.Io) !void {
    const unit = try self.unit_name(alloc);
    defer alloc.free(unit);
    try systemd.stop(io, unit);
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
            self.id.pipeline,
            &self.id.deployment.to_string(),
        },
    );
}

pub fn run_dir_path(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
    return try paths.run(
        alloc,
        self.id.workspace,
        self.id.pipeline,
        &self.id.deployment.to_string(),
    );
}

pub fn archive(self: @This(), alloc: std.mem.Allocator) ![]const u8 {
    return paths.task_archive(
        alloc,
        self.id.workspace,
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
        &self.id.deployment.to_string(),
    );
}

pub const TaskSiblingsIterator = struct {
    task: *const Task,
    dir: ?std.Io.Dir,
    iter: ?std.Io.Dir.Iterator,

    pub fn next(self: *@This(), io: std.Io) !?Task {
        if (self.iter) |*iter| {
            while (true) {
                const task_deployment = self.task.id.deployment.to_string();
                const entry = try iter.next(io) orelse return null;
                if (entry.kind != .directory)
                    continue;
                if (std.mem.eql(u8, &task_deployment, entry.name))
                    continue;
                const dep_id = Deployment.Id.parse(entry.name) catch continue;
                var sibling = self.task.*;
                sibling.id.deployment = dep_id;
                return sibling;
            }
        } else return null;
    }

    pub fn deinit(self: *@This(), io: std.Io) void {
        if (self.dir) |*dir|
            dir.close(io);
    }
};

pub fn siblings(self: *const @This(), alloc: std.mem.Allocator, io: std.Io) !TaskSiblingsIterator {
    const run_dir = try self.run_dir_path(alloc);
    defer alloc.free(run_dir);
    const pipeline_dir = std.fs.path.dirname(run_dir).?;
    const dir = std.Io.Dir.cwd().openDir(io, pipeline_dir, .{ .iterate = true }) catch |err|
        if (err == error.FileNotFound)
            return .{
                .task = self,
                .dir = null,
                .iter = null,
            }
        else
            return err;

    return .{
        .task = self,
        .dir = dir,
        .iter = dir.iterate(),
    };
}

pub fn dupe(self: @This(), alloc: std.mem.Allocator) !@This() {
    return .{
        .id = try self.id.dupe(alloc),
    };
}
pub fn free_duped(self: @This(), alloc: std.mem.Allocator) void {
    self.id.free_duped(alloc);
}

pub fn usage(self: @This(), alloc: std.mem.Allocator, io: std.Io) ?proto.task.poll.TaskUsage {
    const unit = self.unit_name(alloc) catch return null;
    defer alloc.free(unit);

    var cgroup_dir = std.Io.Dir.cwd().openDir(io, "/sys/fs/cgroup/system.slice", .{}) catch |err|
        if (err == error.FileNotFound)
            std.Io.Dir.cwd().openDir(io, "/sys/fs/cgroup", .{}) catch return null
        else
            return null;
    defer cgroup_dir.close(io);

    const unit_dir_name = std.fmt.allocPrint(alloc, "{s}.service", .{unit}) catch return null;
    defer alloc.free(unit_dir_name);

    var svc_dir = cgroup_dir.openDir(io, unit_dir_name, .{}) catch |err|
        if (err == error.FileNotFound)
            cgroup_dir.openDir(io, unit, .{}) catch return null
        else
            return null;
    defer svc_dir.close(io);

    var mem_buf: [64]u8 = undefined;
    var mem_bytes: u64 = 0;
    if (svc_dir.openFile(io, "memory.current", .{ .mode = .read_only })) |f| {
        defer f.close(io);
        const n = f.readPositionalAll(io, &mem_buf, 0) catch 0;
        const s = std.mem.trim(u8, mem_buf[0..n], " \t\r\n");
        mem_bytes = std.fmt.parseInt(u64, s, 10) catch 0;
    } else |_| {}

    var cpu_stat_buf: [1024]u8 = undefined;
    var cpu_usage_usec: u64 = 0;
    if (svc_dir.openFile(io, "cpu.stat", .{ .mode = .read_only })) |f| {
        defer f.close(io);
        const n = f.readPositionalAll(io, &cpu_stat_buf, 0) catch 0;
        var clines = std.mem.splitScalar(u8, cpu_stat_buf[0..n], '\n');
        while (clines.next()) |cline| {
            if (std.mem.startsWith(u8, cline, "usage_usec ")) {
                const num_str = std.mem.trim(u8, cline["usage_usec ".len..], " \t\r\n");
                cpu_usage_usec = std.fmt.parseInt(u64, num_str, 10) catch 0;
            }
        }
    } else |_| {}

    return .{
        .cpu_usec = cpu_usage_usec,
        .memory_bytes = mem_bytes,
    };
}
