const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const dotenv = @import("../util/dotenv.zig");
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

pub fn kill_matching(
    alloc: std.mem.Allocator,
    io: std.Io,
    req: proto.task.kill.Req,
) !void {
    try Task.kill(
        .{ .id = .{
            .workspace = req.workspace,
            .deployment = req.deployment,
            .pipeline = req.pipeline,
        } },
        alloc,
        io,
    );
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
    pub const resolve = Task.resolve;

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.vars);
        alloc.free(self.pkgs);
        alloc.free(self.inputs);
        alloc.free(self.outputs);
    }
};

pub fn resolve(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    config: *const Weft,
    pipeline: *const Weft.Pipeline,
    deployment_id: Deployment.Id,
    project_dir: std.Io.Dir,
    mode: []const u8,
    environ: ?*const std.process.Environ.Map,
    script: []const u8,
) !Spec {
    if (script.len > 50 << 10) {
        term.err("Large scripts/binaries shouldn't be imported as source artifacts", .{});
        return error.ScriptTooLarge;
    }
    // Create a list where the first children environments are at the bottom, and the last
    // parent environments are at the top.
    const env_order: []const []const u8 = env_order: {
        var env_order: std.ArrayList([]const u8) = .empty;
        var todo: std.ArrayList([]const u8) = .empty;
        defer {
            todo.deinit(gpa);
            env_order.deinit(gpa);
        }
        for (pipeline.uses) |uses|
            if (Weft.strip_mode(mode, uses)) |u|
                try todo.insert(gpa, 0, u);

        todo: while (todo.pop()) |sub_env_name| {
            if (Weft.strip_mode(mode, sub_env_name)) |env_name| {
                for (env_order.items) |item| {
                    if (std.mem.eql(u8, item, env_name))
                        continue :todo;
                } else try env_order.append(gpa, env_name);
                const env = config.get_environment(env_name) orelse return error.InvalidEnvornment;
                env_parent: for (env.uses) |env_parent|
                    for (env_order.items) |item| {
                        if (std.mem.eql(u8, item, env_parent))
                            continue :env_parent;
                    } else try env_order.append(gpa, env_parent);
            }
        }
        {
            const env_list = try std.mem.join(gpa, ", ", env_order.items);
            defer gpa.free(env_list);
            term.info("Resolving environment for pipeline {s} in mode {s} as: {s}", .{
                pipeline.name,
                mode,
                env_list,
            });
        }
        std.mem.reverse([]const u8, env_order.items);

        break :env_order try env_order.toOwnedSlice(gpa);
    };
    defer gpa.free(env_order);
    var pkgs: std.ArrayList([]const u8) = .empty;
    defer pkgs.deinit(gpa);
    var env_vars: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer env_vars.deinit(gpa);
    {
        for (env_order) |env_name| {
            const env = config.get_environment(env_name).?;
            for (env.pkgs) |pkg| //PERF: O(N^2)
                for (pkgs.items) |item| {
                    if (std.mem.eql(u8, item, pkg))
                        break;
                } else try pkgs.append(gpa, pkg);
            const env_dotenv = try dotenv.load_env(gpa, io, project_dir, env_name);
            for (env.vars) |env_var| {
                const name = env_var.@"0";

                if (env_var.@"1") |v|
                    try env_vars.put(gpa, name, v)
                else {
                    if (environ) |env_map|
                        if (env_map.get(name)) |val| {
                            try env_vars.put(gpa, name, val);
                            continue;
                        };
                    if (env_dotenv) |dot|
                        if (dot.get(name)) |val| {
                            try env_vars.put(gpa, name, val);
                            continue;
                        };
                    if (env_vars.get(name)) |_|
                        continue;

                    term.err("Environment {s} needed variable {s} but found no value", .{ env_name, name });
                    return error.MissingEnviron;
                }
            }
        }
    }
    const vars = try gpa.alloc(struct { []const u8, []const u8 }, env_vars.size);
    errdefer gpa.free(vars);
    var env_vars_iter = env_vars.iterator();
    var idx: usize = 0;
    while (env_vars_iter.next()) |entry| : (idx += 1) {
        vars[idx].@"0" = entry.key_ptr.*;
        vars[idx].@"1" = entry.value_ptr.*;
    }

    const outputs: []const []const u8 = if (pipeline.out) |o|
        o
    else
        &.{pipeline.name};
    return .{
        .task_id = .{
            .deployment = deployment_id,
            .pipeline = pipeline.name,
            .workspace = config.workspace,
        },
        .script = script,
        .vars = vars,
        .pkgs = try pkgs.toOwnedSlice(gpa),
        .inputs = try gpa.dupe([]const u8, pipeline.in),
        .outputs = try gpa.dupe([]const u8, outputs),
        .keep = pipeline.keep,
        .sibling = pipeline.sibling,
        .tune = pipeline.tune,
    };
}
