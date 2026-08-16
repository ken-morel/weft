const std = @import("std");

const Step = @import("Step.zig");
const Project = @import("Project.zig");
const UUIDv7 = @import("UUIDv7.zig");
const Weft = @import("Weft.zig");

uuid: UUIDv7,

service: Weft,
artifacts: []Artifact = &.{},
running: []Step = &.{},
targets: []Step = &.{},

pub const Artifact = struct {
    step: Step,
    size: u64,
};

pub fn next(self: *const @This()) !?Step {
    const target = self.next_target().?;
    return self.find_next_runnable_input(.from_target(target.*));
}

pub fn next_target(self: @This()) ?*const Step {
    target: for (self.targets) |*target| {
        for (self.artifacts) |artifact|
            if (artifact.step.eq(target.*))
                continue :target;
        return target;
    }
    return null;
}

pub fn next_step(self: @This()) !?Step {
    const target = self.next_target().?;
    const pipeline = try self.resolve_pipeline(target.pipeline);
    return .{
        .remote = target.remote,
        .pipeline = pipeline,
    };
}

pub const StepStatus = union(enum) {
    waits: []const u8,
    needs: []const u8,
    done: void,
    running: void,
    runnable: void,
};

pub fn resolve_pipeline(self: @This(), pipeline_name: []const u8) !StepStatus {
    if (self.service.get_pipeline(pipeline_name)) |pipeline| {
        if (self.get_artifact(pipeline.name))
            return .done;
        if (self.get_running_step(pipeline.name)) |_|
            return .running;

        var waiting: ?[]const u8 = null;
        var needs: ?[]const u8 = null;

        for (pipeline.inputs) |input|
            switch (try self.resolve_pipeline(input.name)) {
                .done => continue,
                .running => |task| waiting = task,
                .waits => |task| waiting = task,
                .needs => |task| needs = task,
                .runnable => needs = input.name,
            };
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

pub fn create(io: std.Io, service: Weft, targets: []Step) !@This() {
    const id = try UUIDv7.now(io);
    return .{
        .uuid = id,
        .service = service,
        .artifacts = &.{},
        .running = &.{},
        .targets = targets,
    };
}

pub fn get_artifact(self: @This(), pipeline: []const u8) ?*const Artifact {
    for (self.artifacts) |*art|
        if (std.mem.eql(u8, art.step.pipeline, pipeline))
            return art;

    return null;
}

pub fn save(self: @This(), io: std.Io, proj: Project) !void {
    var buffer: [1 << 10]u8 = undefined;
    var pos: []u8 = &buffer;
    var filename = try self.uuid.to_string(pos);
    std.mem.copyForwards(u8, pos[filename.len .. filename.len + 4], ".zon");
    filename = pos[0 .. filename.len + 4];
    pos = pos[filename.len + 4 ..];

    const deployments_dir = try proj.open_deployments_dir(io);
    defer deployments_dir.close(io);
    var atomic = try deployments_dir.createFileAtomic(io, filename, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    var writer = atomic.file.writer(io, pos);
    try std.zon.stringify.serializeArbitraryDepth(self, .{}, &writer.interface);
    try writer.flush();
    try atomic.replace(io);
}
