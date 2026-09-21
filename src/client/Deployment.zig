const std = @import("std");

const Weft = @import("../domain/Weft.zig");
const Project = @import("Project.zig");
pub const Step = @import("Step.zig");

id: Id,

config: Weft,
artifacts: []Artifact = &.{},
running: []Step = &.{},
targets: []Step = &.{},

pub const Artifact = struct {
    remote: []const u8,
    pipeline: []const u8,
    name: []const u8,
};

pub const Id = struct {
    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    const epoch_ms: u64 = 1_767_225_600_000;

    const decode_table: [128]u8 = blk: {
        var table: [128]u8 = [_]u8{255} ** 128;
        for (alphabet, 0..) |c, idx|
            table[c] = @intCast(idx);

        break :blk table;
    };

    raw: u64,

    pub fn now(io: std.Io) !@This() {
        const wall_ms = @as(u64, @intCast(std.Io.Clock.now(.real, io).toMilliseconds()));
        const ms_since_epoch = if (wall_ms > epoch_ms) wall_ms - epoch_ms else 0;
        const ticks = ms_since_epoch / 100;
        var salt: [2]u8 = undefined;
        try io.randomSecure(&salt);
        const salt_u15: u64 = std.mem.readInt(u16, &salt, .little) & 0x7FFF;

        return .{
            .raw = (ticks << 15) | salt_u15,
        };
    }

    pub fn to_string(self: @This()) [8]u8 {
        var buf: [8]u8 = undefined;
        var v = self.raw;
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            buf[i] = alphabet[@as(usize, @intCast(v % alphabet.len))];
            v /= alphabet.len;
        }
        return buf;
    }

    pub fn parse(str: []const u8) !@This() {
        if (str.len != 8)
            return error.InvalidLength;
        var val: u64 = 0;
        for (str) |c| {
            if (c >= 128)
                return error.InvalidCharacter;
            const digit = decode_table[c];
            if (digit == 255)
                return error.InvalidCharacter;
            val = val * alphabet.len + digit;
        }
        return .{ .raw = val };
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        const str = self.to_string();
        try writer.writeAll(&str);
    }

    pub fn formatNumber(self: @This(), writer: *std.Io.Writer, num: std.fmt.Number) !void {
        _ = num;
        return self.format(writer);
    }
};

pub fn next_target(self: @This()) ?*const Step {
    target: for (self.targets) |*target| {
        for (self.artifacts) |artifact|
            if (std.mem.eql(u8, artifact.pipeline, target.pipeline) and std.mem.eql(u8, artifact.remote, target.remote))
                continue :target;
        return target;
    }
    return null;
}

pub fn next_step(self: @This()) !?Step {
    target: for (self.targets) |*target| {
        for (self.artifacts) |artifact|
            if (std.mem.eql(u8, artifact.pipeline, target.pipeline) and std.mem.eql(u8, artifact.remote, target.remote))
                continue :target;

        return switch (try self.resolve_pipeline(target.pipeline, 0)) {
            .waits, .running => continue :target,
            .needs => |n| .{
                .remote = target.remote,
                .pipeline = n,
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

pub fn resolve_pipeline(self: @This(), pipeline_name: []const u8, depth: u16) !StepStatus {
    if (depth >= resolve_pipeline_max_depth)
        return error.CyclicPipeline;
    if (self.config.get_pipeline(pipeline_name)) |pipeline| {
        for (pipeline.outputs) |output|
            if (self.get_artifact(output.name)) |_|
                return .done;
        if (pipeline.outputs.len == 0)
            for (self.artifacts) |art|
                if (std.mem.eql(u8, art.pipeline, pipeline_name))
                    return .done;
        if (self.get_running_step(pipeline.name)) |_|
            return .running;

        var waiting: ?[]const u8 = null;
        var needs: ?[]const u8 = null;

        for (pipeline.inputs) |input| {
            other_pipeline: for (self.config.pipelines) |other_pipeline| {
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

pub fn create(io: std.Io, config: Weft, targets: []Step) !@This() {
    const id = try Id.now(io);
    return .{
        .id = id,
        .config = config,
        .artifacts = &.{},
        .running = &.{},
        .targets = targets,
    };
}

pub fn get_artifact(self: @This(), output: []const u8) ?*const Artifact {
    for (self.artifacts) |*art|
        if (std.mem.eql(u8, art.name, output))
            return art;

    return null;
}

pub fn add_running(self: *@This(), alloc: std.mem.Allocator, step: Step) !void {
    self.running = try alloc.realloc(self.running, self.running.len + 1);
    self.running[self.running.len - 1] = step;
}

pub fn remove_running(self: *@This(), alloc: std.mem.Allocator, remote: []const u8, pipeline: []const u8) void {
    for (self.running, 0..) |s, idx| {
        if (std.mem.eql(u8, s.remote, remote) and std.mem.eql(u8, s.pipeline, pipeline)) {
            self.running[idx] = self.running[self.running.len - 1];
            self.running = alloc.realloc(self.running, self.running.len - 1) catch self.running[0 .. self.running.len - 1];
            return;
        }
    }
}

pub fn add_artifact(self: *@This(), alloc: std.mem.Allocator, remote: []const u8, pipeline: ?[]const u8, name: []const u8) !void {
    self.artifacts = try alloc.realloc(self.artifacts, self.artifacts.len + 1);
    self.artifacts[self.artifacts.len - 1] = .{
        .remote = remote,
        .pipeline = pipeline orelse "",
        .name = name,
    };
}

pub fn save(self: @This(), alloc: std.mem.Allocator, io: std.Io, proj: Project) !void {
    var buffer: [1 << 10]u8 = undefined;

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
