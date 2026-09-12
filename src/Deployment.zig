const std = @import("std");

const Project = @import("Project.zig");
pub const Step = @import("Step.zig");
const UUIDv7 = @import("UUIDv7.zig");
const Weft = @import("Weft.zig");

uuid: UUIDv7,

service: Weft,
env: []const u8,
artifacts: []Artifact = &.{},
running: []Step = &.{},
targets: []Step = &.{},

pub const Artifact = struct {
    remote: []const u8,
    name: []const u8,
    size: u64,
};

pub fn next_target(self: @This()) ?*const Step {
    target: for (self.targets) |*target| {
        for (self.artifacts) |artifact|
            if (std.mem.eql(u8, artifact.name, target.pipeline) and std.mem.eql(u8, artifact.remote, target.remote))
                continue :target;
        return target;
    }
    return null;
}

pub fn next_step(self: @This()) !?Step {
    const target = self.next_target() orelse return null;
    return switch (try self.resolve_pipeline(target.pipeline, 0)) {
        .waits, .running => null,
        .needs => |n| .{
            .remote = target.remote,
            .pipeline = n,
        },
        .runnable => target.*,
        .done => return error.Unreachable,
    };
}

pub const StepStatus = union(enum) {
    waits: []const u8,
    needs: []const u8,
    done,
    running,
    runnable,
};

const resolve_pipeline_max_depth: u16 = 100;

pub fn resolve_pipeline(self: @This(), pipeline_name: []const u8, depth: u16) !StepStatus {
    if (depth >= resolve_pipeline_max_depth)
        return error.CyclicPipeline;
    if (self.service.get_pipeline(pipeline_name)) |pipeline| {
        for (pipeline.outputs) |output|
            if (self.get_artifact(output.name)) |_|
                return .done;
        if (self.get_running_step(pipeline.name)) |_|
            return .running;

        var waiting: ?[]const u8 = null;
        var needs: ?[]const u8 = null;

        for (pipeline.inputs) |input| {
            other_pipeline: for (self.service.pipelines) |other_pipeline| {
                blk: {
                    for (other_pipeline.outputs) |output|
                        if (std.mem.eql(u8, output.name, input.name))
                            break :blk;
                    continue :other_pipeline;
                }
                switch (try self.resolve_pipeline(other_pipeline.name, depth + 1)) {
                    .done => continue,
                    .running => waiting = other_pipeline.name,
                    .waits => |task| waiting = task,
                    .needs => |task| needs = task,
                    .runnable => needs = other_pipeline.name,
                }
            }
        }
        if (needs) |task|
            return .{ .needs = task }
        else if (waiting) |task|
            return .{ .waits = task }
        else
            return .runnable;
    } else return error.InvalidPipeline;
}
pub fn get_running_step(self: @This(), pipeline: []const u8) ?*const Step {
    for (self.running) |*running|
        if (std.mem.eql(u8, running.pipeline, pipeline))
            return running;
    return null;
}

pub fn completed(self: @This()) bool {
    return self.next_target() == null;
}

pub fn create(io: std.Io, service: Weft, env: []const u8, targets: []Step) !@This() {
    const id = try UUIDv7.now(io);
    return .{
        .uuid = id,
        .service = service,
        .artifacts = &.{},
        .running = &.{},
        .targets = targets,
        .env = env,
    };
}

pub fn get_artifact(self: @This(), output: []const u8) ?*const Artifact {
    for (self.artifacts) |*art|
        if (std.mem.eql(u8, art.name, output))
            return art;

    return null;
}

pub fn save(self: @This(), alloc: std.mem.Allocator, io: std.Io, proj: Project) !void {
    var buffer: [1 << 10]u8 = undefined;

    const filename = try std.fmt.allocPrint(alloc, "{x}.zon", .{self.uuid});
    defer alloc.free(filename);

    const deployments_dir = try proj.open_deployment_dir(io, self.uuid);
    defer deployments_dir.close(io);
    var atomic = try deployments_dir.createFileAtomic(io, filename, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    var writer = atomic.file.writer(io, &buffer);
    try std.zon.stringify.serializeArbitraryDepth(self, .{}, &writer.interface);
    try writer.flush();
    try atomic.replace(io);
}
