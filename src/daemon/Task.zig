const std = @import("std");
const log = std.log.scoped;

const Deployment = @import("../client/Deployment.zig");
const DotEnv = @import("../domain/DotEnv.zig");
const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const Weft = @import("../domain/Weft.zig");
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
    skip_self: bool,

    pub fn next(self: *@This(), io: std.Io) !?Task {
        const ignore_deployment = if (self.skip_self)
            self.task.id.deployment.to_string()
        else
            null;
        return if (self.iter) |*iter|
            while (try iter.next(io)) |entry| {
                if (entry.kind != .directory)
                    continue
                else if (ignore_deployment) |i|
                    if (std.mem.eql(u8, entry.name, &i))
                        continue
                    else {}
                else {
                    const dep_id = Deployment.Id.parse(entry.name) catch continue;
                    var sibling = self.task.*;
                    sibling.id.deployment = dep_id;
                    break sibling;
                }
            } else null
        else
            null;
    }

    pub fn deinit(self: *@This(), io: std.Io) void {
        if (self.dir) |*dir|
            dir.close(io);
    }
};

pub fn siblings(self: *const @This(), alloc: std.mem.Allocator, io: std.Io, skip_self: bool) !TaskSiblingsIterator {
    const run_dir = try self.run_dir_path(alloc);
    defer alloc.free(run_dir);
    const pipeline_dir = std.fs.path.dirname(run_dir).?;
    const dir = std.Io.Dir.cwd().openDir(io, pipeline_dir, .{ .iterate = true }) catch |err|
        if (err == error.FileNotFound)
            return .{
                .task = self,
                .dir = null,
                .iter = null,
                .skip_self = skip_self,
            }
        else
            return err;

    return .{
        .task = self,
        .dir = dir,
        .iter = dir.iterate(),
        .skip_self = skip_self,
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

pub const Spec = struct {
    pub const Tune = Weft.Pipeline.Tune;
    task_id: proto.task.Id,
    script: []const u8,
    vars: []const struct { []const u8, []const u8 } = &.{},
    pkgs: []const []const u8 = &.{},
    inputs: []const []const u8 = &.{},
    outputs: []const []const u8 = &.{},
    keep: []const Weft.Keep = &.{},
    sibling: Weft.Pipeline.HandleSibling = .{ .then = .ignore },
    tune: Tune,
    mode: []const u8,

    pub const Env = struct {
        vars: []const struct { []const u8, []const u8 } = &.{},
        pkgs: []const []const u8 = &.{},
    };

    pub fn resolve_env_leaky(gpa: std.mem.Allocator, alloc: std.mem.Allocator, io: std.Io, mode: []const u8, envs: []const Weft.Env, dotenv: DotEnv, env: Weft.Env) !Env {
        return _resolve_env_leaky(gpa, alloc, io, mode, envs, dotenv, env, 0);
    }

    pub fn _resolve_env_leaky(gpa: std.mem.Allocator, ara: std.mem.Allocator, io: std.Io, mode: []const u8, envs: []const Weft.Env, dotenv: DotEnv, env: Weft.Env, level: u8) !Env {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        const l = log(.env_resolve);
        if (level > 100) {
            l.err("Went more than 100 levels deep at '{s}' while resolving envirnment", .{env.name});
            return error.EnvCycle;
        }

        var parents: std.ArrayList(Env) = try .initCapacity(alloc, env.uses.len);
        for (env.uses) |use_spec| {
            if (Weft.strip_mode(mode, use_spec)) |use_name| {
                const use: Env = for (envs) |use| {
                    if (std.mem.eql(u8, use.name, use_name))
                        break try _resolve_env_leaky(gpa, alloc, io, mode, envs, dotenv, use, level + 1);
                } else {
                    l.err("Environment {s} uses environment {s} which doesn't exist", .{ env.name, use_name });
                    return error.EnvironNotFound;
                };
                parents.appendAssumeCapacity(use);
            }
        }
        var pkgs: std.ArrayList([]const u8) = .empty;
        defer pkgs.deinit(gpa);
        try pkgs.appendSlice(gpa, env.pkgs);
        for (parents.items) |parent|
            for (parent.pkgs) |pkg|
                for (pkgs.items) |item| {
                    if (std.mem.eql(u8, item, pkg))
                        break;
                } else try pkgs.append(gpa, try ara.dupe(u8, pkg));

        var env_vars: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer env_vars.deinit(gpa);
        for (env.vars) |env_var|
            if (Weft.strip_mode(mode, env_var.@"0")) |name| {
                if (env_var.@"1" orelse dotenv.get(env.name, name)) |val|
                    try env_vars.put(gpa, name, val)
                else parent: for (parents.items) |parent| {
                    for (parent.vars) |parent_var|
                        if (std.mem.eql(u8, parent_var.@"0", name)) {
                            try env_vars.put(gpa, name, try ara.dupe(u8, parent_var.@"1"));
                            break :parent;
                        };
                } else {
                    l.err("Environment {s} requires variable {s} which couldn't be found in mode {s}", .{ env.name, name, mode });
                    return error.MissingEnviron;
                }
            };

        const final_vars = try ara.alloc(struct { []const u8, []const u8 }, env_vars.size);
        var env_vars_iter = env_vars.iterator();
        var i: usize = 0;
        while (env_vars_iter.next()) |entry| : (i += 1) {
            final_vars[i].@"0" = entry.key_ptr.*;
            final_vars[i].@"1" = entry.value_ptr.*;
        }
        // NOTE: All values from parents have to be duped
        return .{
            .pkgs = try pkgs.toOwnedSlice(ara),
            .vars = final_vars,
        };
    }

    pub fn resolve_leaky(
        gpa: std.mem.Allocator,
        ara: std.mem.Allocator,
        io: std.Io,
        config: *const Weft,
        pipeline: *const Weft.Pipeline,
        deployment_id: Deployment.Id,
        mode: []const u8,
        dotenv: DotEnv,
        script: []const u8,
    ) !@This() {
        const l = log(.task_resolve);
        if (script.len > 40 << 10) {
            l.err("Large scripts/binaries should be imported as source artifacts", .{});
            return error.ScriptTooLarge;
        }
        const env = try resolve_env_leaky(gpa, ara, io, mode, config.environments, dotenv, pipeline.environ());
        const outputs: []const []const u8 = if (pipeline.out) |o|
            o
        else
            try ara.dupe([]const u8, &.{pipeline.name});

        var keep: std.ArrayList(Weft.Keep) = try .initCapacity(gpa, pipeline.keep.len);
        defer keep.deinit(gpa);
        for (pipeline.keep) |k|
            if (Weft.strip_mode(mode, k.@"0")) |name|
                try keep.append(gpa, .{ name, k.@"1" });

        return .{
            .task_id = .{
                .deployment = deployment_id,
                .pipeline = pipeline.name,
                .workspace = config.workspace,
            },
            .script = script,
            .vars = env.vars,
            .pkgs = env.pkgs,
            .inputs = pipeline.in,
            .outputs = outputs,
            .keep = try keep.toOwnedSlice(ara),
            .sibling = pipeline.sibling,
            .tune = pipeline.tune,
            .mode = mode,
        };
    }
};
