const std = @import("std");
const log = std.log.scoped;

const Deployment = @import("../client/Deployment.zig");
const domain = @import("../domain/domain.zig");
const DotEnv = @import("../domain/DotEnv.zig");
const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
pub const Id = proto.task.Id;
const Weft = @import("../domain/Weft.zig");
const Workspace = @import("../domain/Workspace.zig");
const CGroup2 = @import("../util/CGroup2.zig");
const zoto = @import("../util/zoto.zig");

const Task = @This();

pub const Status = union(enum) {
    preparing,
    running,
    harvesting,
    done,
    skipped,
    failed,
    killed,
    frozen,
};

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

pub fn get_workspace(self: @This()) Workspace {
    return .{
        .name = self.id.workspace,
    };
}

pub fn from_cgroup_name(name: []const u8) ?@This() {
    if (std.mem.containsAtLeast(u8, name, 1, "--"))
        return from_unit_name(name);

    var iter = std.mem.splitSequence(u8, name, "/");
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
pub fn write_spec(self: @This(), gpa: std.mem.Allocator, io: std.Io, spec: Spec) !void {
    const l = log(.task_io);
    const cwd: std.Io.Dir = .cwd();

    const spec_path = try gpa.print(paths.task_spec, self.id.wpd());
    defer gpa.free(spec_path);
    l.debug("writing spec to {s}", .{spec_path}); //debug

    var atomic = try cwd.createFileAtomic(io, spec_path, .{
        .make_path = true,
        .permissions = domain.read_only_user_permissions,
        .replace = true,
    });
    defer atomic.deinit(io);

    var buf: [4 << 10]u8 = undefined;
    var writer = atomic.file.writer(io, &buf);
    try zoto.serialize(
        &writer.interface,
        Task.Spec,
        spec,
        .{ .header = true },
    );
    try writer.flush();
    try atomic.replace(io);
}
pub fn read_spec(self: @This(), gpa: std.mem.Allocator, ara: std.mem.Allocator, io: std.Io) !Spec {
    const l = log(.task_io);
    const spec_path = try gpa.print(paths.task_spec, self.id.wpd());
    defer gpa.free(spec_path);
    l.debug("reading spec from {s}", .{spec_path}); //debug
    var txt: []const u8 = try std.Io.Dir.cwd().readFileAlloc(io, spec_path, ara, .limited64(Task.Spec.max_size));
    return try zoto.deserialize(ara, &txt, Task.Spec, .{ .header = true });
}

pub fn write_status(self: @This(), gpa: std.mem.Allocator, io: std.Io, status: Status) !void {
    const l = log(.task_io);
    l.debug("status -> {s}", .{@tagName(status)}); //debug
    const str = try zoto.serializeAlloc(gpa, Status, status, .{ .header = true });
    const status_path = try gpa.print(paths.task_status, self.id.wpd());
    defer gpa.free(status_path);
    try domain.write_file_atomic(io, .cwd(), status_path, str, .{});
}
pub fn read_status(self: @This(), gpa: std.mem.Allocator, io: std.Io) !Status {
    const status_path = try gpa.print(paths.task_status, self.id.wpd());
    defer gpa.free(status_path);
    var content: []const u8 = try std.Io.Dir.cwd().readFileAlloc(io, status_path, gpa, .unlimited);
    defer gpa.free(content);
    return zoto.deserialize(null, &content, Status, .{ .header = true });
}

pub fn kill(self: @This(), gpa: std.mem.Allocator, io: std.Io) !void {
    const l = log(.task_io);
    l.debug("killing task {s}/{s}/{d}", .{ self.id.workspace, self.id.pipeline, self.id.deployment }); //debug
    const cg = try self.cgroup(gpa);
    defer cg.deinit(gpa);
    try cg.kill(gpa, io);
}

pub fn is_active(self: @This(), gpa: std.mem.Allocator, io: std.Io) !bool {
    const cg = try self.cgroup(gpa);
    defer cg.deinit(gpa);
    return cg.is_active(gpa, io);
}

pub fn cgroup_name(self: @This(), gpa: std.mem.Allocator) ![]const u8 {
    return try std.fs.path.join(gpa, &.{
        self.id.workspace,
        self.id.pipeline,
        &self.id.deployment.to_string(),
    });
}
pub fn cgroup(self: @This(), gpa: std.mem.Allocator) !CGroup2 {
    const name = try self.cgroup_name(gpa);
    defer gpa.free(name);
    return try .init(gpa, name);
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

pub fn siblings(self: *const @This(), gpa: std.mem.Allocator, io: std.Io, skip_self: bool) !TaskSiblingsIterator {
    const l = log(.task_io);
    const tasks_run = try gpa.print(paths.tasks_run_parent, self.id.wp());
    defer gpa.free(tasks_run);
    const dir = std.Io.Dir.cwd().openDir(io, tasks_run, .{ .iterate = true }) catch |err|
        if (err == error.FileNotFound)
            return .{
                .task = self,
                .dir = null,
                .iter = null,
                .skip_self = skip_self,
            }
        else
            return err;

    l.debug("listing sibling deployments in {s}", .{tasks_run}); //debug
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

pub fn usage(self: @This(), gpa: std.mem.Allocator, io: std.Io) !?proto.task.poll.TaskUsage {
    const cg = self.cgroup(gpa) catch return null;
    defer cg.deinit(gpa);

    const mem_bytes = cg.memory_current_get(gpa, io) catch |e|
        if (e == error.Canceled)
            return e
        else
            0;

    const cpu: CGroup2.CpuStat = cg.cpu_stat_get(gpa, io) catch |e|
        if (e == error.Canceled)
            return e
        else
            .{};

    return .{
        .cpu_usec = cpu.usage_usec,
        .memory_bytes = mem_bytes,
    };
}

pub const Spec = struct {
    pub const Tune = Weft.Pipeline.Tune;
    pub const max_size = 64 << 10; //TODO: Make sure we use this everywhere
    pub const max_script_size = 60 << 10; //TODO: Make sure we use this everywhere

    task_id: proto.task.Id,
    script: ?[]const u8,
    timeout: ?u32 = null,
    vars: []const struct { []const u8, []const u8 } = &.{},
    pkgs: []const []const u8 = &.{},
    inputs: []const []const u8 = &.{},
    outputs: []const []const u8 = &.{},
    keep: []const Weft.Keep = &.{},
    sibling: Weft.Pipeline.HandleSibling = .{ .then = .ignore },
    tune: Tune,
    mode: []const u8,
    retention: Weft.Retention,

    pub const Env = struct {
        vars: []const struct { []const u8, []const u8 } = &.{},
        pkgs: []const []const u8 = &.{},
    };

    pub fn resolve_env_leaky(gpa: std.mem.Allocator, ara: std.mem.Allocator, io: std.Io, mode: []const u8, envs: []const Weft.Env, dotenv: DotEnv, env: Weft.Env) !Env {
        return _resolve_env_leaky(gpa, ara, io, mode, envs, dotenv, env, 0);
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
                const use: Env = for (envs) |envs_entry| {
                    if (std.mem.eql(u8, envs_entry.name, use_name))
                        break try _resolve_env_leaky(
                            gpa,
                            alloc,
                            io,
                            mode,
                            envs,
                            dotenv,
                            envs_entry,
                            level + 1,
                        );
                } else {
                    l.err("Environment {s} uses environment {s} which doesn't exist", .{ env.name, use_name });
                    return error.EnvironNotFound;
                };
                parents.appendAssumeCapacity(use);
            }
        }
        var pkgs: std.ArrayList([]const u8) = try .initCapacity(ara, env.pkgs.len);
        for (env.pkgs) |pkg|
            if (Weft.strip_mode(mode, pkg)) |p|
                pkgs.appendAssumeCapacity(try ara.dupe(u8, p));
        for (parents.items) |parent|
            for (parent.pkgs) |pkg|
                if (Weft.strip_mode(mode, pkg)) |p|
                    for (pkgs.items) |item| {
                        if (std.mem.eql(u8, item, p))
                            break;
                    } else try pkgs.append(ara, try ara.dupe(u8, p));

        var env_vars: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (env.vars) |env_var|
            if (Weft.strip_mode(mode, env_var.@"0")) |name| {
                if (env_var.@"1" orelse dotenv.get(env.name, name)) |val|
                    try env_vars.put(alloc, name, val)
                else parent: for (parents.items) |parent| {
                    for (parent.vars) |parent_var|
                        if (std.mem.eql(u8, parent_var.@"0", name)) {
                            try env_vars.put(alloc, name, parent_var.@"1");
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
            final_vars[i].@"0" = try ara.dupe(u8, entry.key_ptr.*);
            final_vars[i].@"1" = try ara.dupe(u8, entry.value_ptr.*);
        }
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
        script: ?[]const u8,
    ) !@This() {
        const l = log(.task_resolve);
        if (script) |s|
            if (s.len > max_script_size) {
                l.err("Large scripts/binaries should be imported as source artifacts", .{});
                return error.ScriptTooLarge;
            };
        const env = try resolve_env_leaky(gpa, ara, io, mode, config.environments, dotenv, pipeline.environ());
        const outputs: []const []const u8 = if (pipeline.out) |o|
            o
        else
            try ara.dupe([]const u8, &.{pipeline.name});

        var keep: std.ArrayList(Weft.Keep) = try .initCapacity(ara, pipeline.keep.len);
        for (pipeline.keep) |k|
            if (Weft.strip_mode(mode, k.@"0")) |name|
                keep.appendAssumeCapacity(.{ try ara.dupe(u8, name), try ara.dupe(u8, k.@"1") });

        return .{
            .task_id = .{
                .deployment = deployment_id,
                .pipeline = pipeline.name,
                .workspace = config.workspace,
            },
            .script = script,
            .timeout = pipeline.timeout,
            .vars = env.vars,
            .pkgs = env.pkgs,
            .inputs = pipeline.in,
            .outputs = outputs,
            .keep = try keep.toOwnedSlice(ara),
            .sibling = pipeline.sibling,
            .tune = pipeline.tune,
            .mode = mode,
            .retention = pipeline.retention orelse config.retention,
        };
    }
};
