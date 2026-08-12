const std = @import("std");

pub const Service = @import("Service.zig");
pub const Workspace = @import("Workspace.zig");
pub const Target = @import("Target.zig");
const Project = @import("Project.zig");
const UUIDv7 = @import("UUIDv7.zig");
const install = @import("install.zig");

uuid: UUIDv7,

service: Service,

artifacts: []Artifact = &.{},
running: []Running = &.{},
targets: []Target = &.{},

pub const Running = struct {
    remote: []const u8,
    pipeline: []const u8,
};

pub const Artifact = struct {
    consumed: bool = false,
    remote: ?[]const u8,
    pipeline: []const u8,
    exit_code: u8,
};

pub const NextStep = struct {
    remote: []const u8,
    pipeline: []const u8,
    pub fn from_target(t: Target) @This() {
        return .{
            .remote = t.remote,
            .pipeline = t.pipeline,
        };
    }
    pub fn could_match(self: @This(), running: Running) bool {
        return std.mem.eql(u8, self.pipeline, running.pipeline) and std.mem.eql(u8, self.remote, running.remote);
    }
    pub fn cmp(a: @This(), b: @This()) i2 {
        return if (a.gt(b))
            1
        else if (b.gt(a))
            -1
        else
            0;
    }
    pub fn gt(a: @This(), b: @This()) bool {
        _ = a;
        _ = b;
        return false;
    }
};

pub fn next(self: *const @This()) !?NextStep {
    const target = self.next_target().?;
    return self.find_next_runnable_input(.from_target(target.*));
}

/// asumes any existing artifact from the pipeline isn't satisfying
pub fn find_next_runnable_input(self: @This(), final_step: NextStep) !?NextStep {
    var step = final_step;
    pipeline: while (self.service.get_pipeline(step.pipeline)) |pipeline| {
        if (self.get_running_pipeline(pipeline.name)) |running|
            if (step.could_match(running.*))
                return null;
        input: for (pipeline.inputs) |pipeline_input| {
            switch (pipeline_input) {
                .src => continue :input,
                .artifact => |input| {
                    for (self.artifacts) |artifact|
                        if (input.matches(artifact))
                            continue :input;
                    if (self.get_running_pipeline(input.pipeline)) |running_input_provider|
                        if (input.could_match(running_input_provider.*))
                            continue :input;

                    step = .{
                        .pipeline = input.pipeline,
                        .remote = step.remote,
                    };
                    continue :pipeline;
                },
            }
        }
        return step;
    }
    std.debug.panic("Invalid pipeline: {s}", .{step.pipeline});
}
pub fn get_running_pipeline(self: @This(), pipeline: []const u8) ?*const Running {
    for (self.running) |*running|
        if (std.mem.eql(u8, running.pipeline, pipeline))
            return running;
    return null;
}
pub fn next_target(self: @This()) ?*const Target {
    target: for (self.targets) |*target| {
        for (self.artifacts) |artifact|
            if (target.matches(artifact))
                continue :target;
        return target;
    }
    return null;
}
pub fn completed(self: @This()) bool {
    return self.next_target() == null;
}

pub fn create(alloc: std.mem.Allocator, io: std.Io, service: Service, targets: []Target) !@This() {
    const id = try UUIDv7.new(io);

    return .{
        .uuid = id,
        .service = service,
        .artifacts = try alloc.alloc(Artifact, 0),
        .running = &.{},
        .targets = targets,
    };
}

pub fn save(self: *const @This(), io: std.Io, proj: Project) !void {
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
