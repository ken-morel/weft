const std = @import("std");

const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
pub const Id = @import("DeploymentId.zig");
const Project = @import("Project.zig");
pub const Step = @import("Step.zig");

id: Id,

config: Weft,
artifacts: []Artifact = &.{},
sources: [][]const u8 = &.{},
running: []Step = &.{},
targets: []Step = &.{},

pub const Artifact = struct {
    remote: []const u8,
    pipeline: []const u8,
    name: []const u8,
};

pub fn get_artifact(self: @This(), output: []const u8) ?Artifact {
    return for (self.artifacts) |art| {
        if (std.mem.eql(u8, output, art.name))
            break art;
    } else null;
}

/// This function will be removed
pub fn get_pipeline_artifact(self: @This(), pipeline: ?[]const u8, output: ?[]const u8) ?Artifact {
    return for (self.artifacts) |art| {
        if (pipeline) |p|
            if (std.mem.eql(u8, p, art.pipeline))
                if (output) |o|
                    if (std.mem.eql(u8, art.name, o))
                        break art
                    else
                        continue
                else
                    break art
            else {}
        else if (output) |o|
            if (std.mem.eql(u8, o, art.name))
                break art
            else {};
    } else null;
}

pub fn next_target(self: @This()) ?Step {
    return for (self.targets) |target| {
        if (self.get_pipeline_artifact(target.pipeline, null)) |_|
            continue
        else
            break target;
    } else null;
}

pub fn next_step(self: @This(), term: *Term) !?Step {
    target: for (self.targets) |*target| {
        if (self.get_pipeline_artifact(target.pipeline, null)) |_|
            continue :target;

        return switch (try self.resolve_pipeline(term, target.pipeline, 0)) {
            .waits, .running => continue :target,
            .needs => |n| .{
                .remote = target.remote,
                .pipeline = n,
                .mode = target.mode,
            },
            .runnable => target.*,
            .done => continue :target,
        };
    }
    return null;
}

pub const StepStatus = union(enum) {
    waits: []const u8,
    needs: []const u8,
    done,
    running,
    runnable,
};

const resolve_pipeline_max_depth: u16 = 100;

pub fn resolve_pipeline(self: @This(), term: *Term, pipeline_name: []const u8, depth: u16) !StepStatus {
    if (depth >= resolve_pipeline_max_depth)
        return error.CyclicPipeline;
    const pipeline = self.config.get_pipeline(pipeline_name) orelse return error.InvalidPipeline;
    const outs: []const []const u8 = pipeline.out orelse &.{pipeline.name};
    for (outs) |output|
        if (self.get_artifact(output)) |_|
            return .done;
    if (self.get_running_step(pipeline.name)) |_|
        return .running;

    var waiting: ?[]const u8 = null;
    var needs: ?[]const u8 = null;

    input: for (pipeline.in) |in| {
        if (Weft.is_source_artifact(in))
            continue :input;
        const producer = self.config.get_producer(in) orelse {
            term.err("Pipeline {s} has input {s} not provided by any other pipeline", .{ pipeline_name, in });

            return error.InvalidInput;
        };
        switch (try self.resolve_pipeline(
            term,
            producer.name,
            depth + 1,
        )) {
            .done => continue :input,
            .running => waiting = producer.name,
            .waits => |task| waiting = task,
            .needs => |task| needs = task,
            .runnable => needs = producer.name,
        }
    }

    return if (needs) |task|
        .{ .needs = task }
    else if (waiting) |task|
        .{ .waits = task }
    else
        .runnable;
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

pub fn init(io: std.Io, config: Weft, targets: []Step) !@This() {
    const id = try Id.now(io);
    return .{
        .id = id,
        .config = config,
        .artifacts = &.{},
        .running = &.{},
        .targets = targets,
    };
}

pub fn add_running(self: *@This(), alloc: std.mem.Allocator, step: Step) !void {
    self.running = try alloc.realloc(self.running, self.running.len + 1);
    self.running[self.running.len - 1] = step;
}

pub fn remove_running(self: *@This(), alloc: std.mem.Allocator, remote: []const u8, pipeline: []const u8) void {
    for (self.running, 0..) |s, idx|
        if (std.mem.eql(u8, s.remote, remote) and std.mem.eql(u8, s.pipeline, pipeline)) {
            self.running[idx] = self.running[self.running.len - 1];
            self.running = alloc.realloc(self.running, self.running.len - 1) catch self.running[0 .. self.running.len - 1];
            return;
        };
}

pub fn add_artifact(self: *@This(), alloc: std.mem.Allocator, art: Artifact) !void {
    self.artifacts = try alloc.realloc(self.artifacts, self.artifacts.len + 1);
    self.artifacts[self.artifacts.len - 1] = art;
}

pub fn add_source(self: *@This(), alloc: std.mem.Allocator, src: []const u8) !void {
    self.sources = try alloc.realloc(self.sources, self.sources.len + 1);
    self.sources[self.sources.len - 1] = try alloc.dupe(u8, src);
}

pub fn save(self: @This(), alloc: std.mem.Allocator, io: std.Io, proj: Project) !void {
    var buffer: [1 << 5]u8 = undefined;

    const filename = try std.fmt.allocPrint(alloc, "{s}.zon", .{&self.id.to_string()});
    defer alloc.free(filename);

    const deployments_dir = try proj.open_deployment_dir(io, self.id);
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
