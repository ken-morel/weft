const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const paths = @import("../domain/paths.zig");
const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
pub const Database = Weft.Env.Database;
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

pub fn kill_matching(
    alloc: std.mem.Allocator,
    io: std.Io,
    req: proto.task.kill.Req,
) !u32 {
    var killed_count: u32 = 0;

    var run_dir = std.Io.Dir.cwd().openDir(io, paths.weft_run_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer run_dir.close(io);

    var ws_iter = run_dir.iterate();
    while (try ws_iter.next(io)) |ws_entry| {
        if (ws_entry.kind != .directory) continue;
        if (req.workspace.len > 0 and !std.mem.eql(u8, req.workspace, ws_entry.name)) continue;

        const ws_path = try std.fs.path.join(alloc, &.{ paths.weft_run_dir, ws_entry.name });
        defer alloc.free(ws_path);
        var ws_dir = std.Io.Dir.cwd().openDir(io, ws_path, .{ .iterate = true }) catch continue;
        defer ws_dir.close(io);

        var p_iter = ws_dir.iterate();
        while (try p_iter.next(io)) |p_entry| {
            if (p_entry.kind != .directory) continue;
            if (req.pipeline) |p| {
                if (!std.mem.eql(u8, p, p_entry.name)) continue;
            }

            const pipe_path = try std.fs.path.join(alloc, &.{ ws_path, p_entry.name });
            defer alloc.free(pipe_path);
            var pipe_dir = std.Io.Dir.cwd().openDir(io, pipe_path, .{ .iterate = true }) catch continue;
            defer pipe_dir.close(io);

            var d_iter = pipe_dir.iterate();
            while (try d_iter.next(io)) |d_entry| {
                if (d_entry.kind != .directory) continue;
                const dep_id = Deployment.Id.parse(d_entry.name) catch continue;
                if (req.deployment) |d| {
                    if (d.raw != dep_id.raw) continue;
                }

                const t: Task = .{ .id = .{
                    .workspace = ws_entry.name,
                    .deployment = dep_id,
                    .pipeline = p_entry.name,
                } };
                if (t.is_active(alloc, io) catch false) {
                    t.kill(alloc, io) catch {};
                    killed_count += 1;
                }
            }
        }
    }
    return killed_count;
}

pub const Spec = struct {
    task: proto.task.Id,
    script: []const u8,
    vars: []const struct { []const u8, []const u8 } = &.{},
    pkgs: []const []const u8 = &.{},
    databases: []const Database = &.{},
    inputs: []const []const u8 = &.{},
    outputs: []const []const u8 = &.{},
    keep: []const Weft.Keep = &.{},
    second_instance: Weft.Pipeline.SecondInstance = .ignore,

    memory_max: ?u64 = null,
    memory_high: ?u64 = null,
    cpu_quota: ?u16 = null,
    tasks_max: ?u32 = null,
    io_weight: ?u32 = null,
    timeout: ?u32 = null,

    pub const resolve = Task.resolve;

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        for (self.vars) |v| {
            alloc.free(v.@"0");
            alloc.free(v.@"1");
        }
        alloc.free(self.vars);
        alloc.free(self.pkgs);
        alloc.free(self.databases);
        alloc.free(self.inputs);
        alloc.free(self.outputs);
    }
};

pub fn resolve(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    config: *const Weft,
    pipeline: *const Weft.Pipeline,
    deployment: Deployment.Id,
    project_dir: ?std.Io.Dir,
    base_env_name: ?[]const u8,
    base_env: ?*const std.process.Environ.Map,
    script: []const u8,
) !Spec {
    if (script.len > 60 * 1024) {
        term.err(
            "pipeline '{s}': script size ({d} bytes) exceeds 60KB limit",
            .{ pipeline.name, script.len },
        );
        return error.ScriptTooLarge;
    }

    var env_order: std.ArrayList([]const u8) = .empty;
    defer env_order.deinit(alloc);

    var visiting: std.StringHashMapUnmanaged(void) = .empty;
    defer visiting.deinit(alloc);

    var visited: std.StringHashMapUnmanaged(void) = .empty;
    defer visited.deinit(alloc);

    const Walker = struct {
        fn visit(
            env_name: []const u8,
            a: std.mem.Allocator,
            cfg: *const Weft,
            p_name: []const u8,
            t: *Term,
            vis: *std.StringHashMapUnmanaged(void),
            vstd: *std.StringHashMapUnmanaged(void),
            ord: *std.ArrayList([]const u8),
        ) anyerror!void {
            if (vstd.contains(env_name)) return;
            if (vis.contains(env_name)) {
                t.err("pipeline '{s}': cyclic dependency detected on environment '{s}'", .{ p_name, env_name });
                return error.CyclicDependency;
            }
            try vis.put(a, env_name, {});
            const env = cfg.get_environment(env_name) orelse {
                t.err("pipeline '{s}': referenced environment '{s}' not found", .{ p_name, env_name });
                return error.EnvironmentNotFound;
            };
            for (env.uses) |dep_name| {
                try visit(dep_name, a, cfg, p_name, t, vis, vstd, ord);
            }
            _ = vis.remove(env_name);
            try vstd.put(a, env_name, {});
            try ord.append(a, env_name);
        }
    };

    if (base_env_name) |ben| {
        if (ben.len > 0)
            try Walker.visit(ben, alloc, config, pipeline.name, term, &visiting, &visited, &env_order);
    }

    for (pipeline.uses) |root_env|
        try Walker.visit(root_env, alloc, config, pipeline.name, term, &visiting, &visited, &env_order);

    var loaded_dotenvs: std.ArrayList(dotenv.DotEnv) = .empty;
    defer {
        for (loaded_dotenvs.items) |*d|
            d.deinit(alloc);
        loaded_dotenvs.deinit(alloc);
    }

    var vars_map: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    defer vars_map.deinit(alloc);

    for (env_order.items) |env_name| {
        const env = config.get_environment(env_name).?;
        var env_de: ?*const dotenv.DotEnv = null;
        if (project_dir) |dir| {
            const filename = try std.fmt.allocPrint(alloc, ".env.{s}", .{env.name});
            defer alloc.free(filename);
            if (try dotenv.load_file(alloc, io, dir, filename)) |de| {
                try loaded_dotenvs.append(alloc, de);
                env_de = &loaded_dotenvs.items[loaded_dotenvs.items.len - 1];
            }
        }
        for (env.vars) |v| {
            if (v.@"1") |val|
                try vars_map.put(alloc, v.@"0", val)
            else if (env_de) |de| {
                if (de.get(v.@"0")) |val|
                    try vars_map.put(alloc, v.@"0", val)
                else if (!vars_map.contains(v.@"0"))
                    try vars_map.put(alloc, v.@"0", null);
            } else if (!vars_map.contains(v.@"0"))
                try vars_map.put(alloc, v.@"0", null);
        }
    }

    var global_dotenv: ?dotenv.DotEnv = null;
    defer if (global_dotenv) |*gd| gd.deinit(alloc);

    if (project_dir) |dir|
        global_dotenv = try dotenv.load_file(alloc, io, dir, ".env");

    var final_vars: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    errdefer {
        for (final_vars.items) |v| {
            alloc.free(v.@"0");
            alloc.free(v.@"1");
        }
        final_vars.deinit(alloc);
    }

    var iter = vars_map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = if (entry.value_ptr.*) |v|
            v
        else if (global_dotenv) |gd|
            gd.get(key) orelse if (base_env) |be| be.get(key) orelse null else null
        else if (base_env) |be|
            be.get(key) orelse null
        else
            null;

        if (val) |v| {
            const duped_key = try alloc.dupe(u8, key);
            errdefer alloc.free(duped_key);
            const duped_val = try alloc.dupe(u8, v);
            errdefer alloc.free(duped_val);
            try final_vars.append(alloc, .{ duped_key, duped_val });
        } else {
            term.err("pipeline '{s}': required environment variable '{s}' is unset", .{ pipeline.name, key });
            return error.MissingRequiredEnv;
        }
    }

    var pkgs_list: std.ArrayList([]const u8) = .empty;
    errdefer pkgs_list.deinit(alloc);

    for (env_order.items) |env_name| {
        const env = config.get_environment(env_name).?;
        for (env.pkgs) |pkg|
            for (pkgs_list.items) |existing| {
                if (std.mem.eql(u8, existing, pkg))
                    break;
            } else try pkgs_list.append(alloc, pkg);
    }

    var databases_list: std.ArrayList(Database) = .empty;
    errdefer databases_list.deinit(alloc);

    for (env_order.items) |env_name| {
        const env = config.get_environment(env_name).?;
        for (env.databases) |db|
            for (databases_list.items) |existing| {
                if (std.mem.eql(u8, existing.name, db.name)) {
                    if (existing.type != db.type) {
                        term.err("pipeline '{s}': conflicting database type for '{s}'", .{ pipeline.name, db.name });
                        return error.ConflictingDatabase;
                    }
                    break;
                }
            } else try databases_list.append(alloc, .{
                .name = db.name,
                .type = db.type,
            });
    }

    const inputs_list = try alloc.dupe([]const u8, pipeline.inputs());
    errdefer alloc.free(inputs_list);

    var out_buf: [1][]const u8 = undefined;
    const outs = pipeline.outputs(&out_buf);
    const outputs_list = try alloc.dupe([]const u8, outs);
    errdefer alloc.free(outputs_list);

    return .{
        .task = .{
            .workspace = config.workspace,
            .deployment = deployment,
            .pipeline = pipeline.name,
        },
        .script = script,
        .vars = try final_vars.toOwnedSlice(alloc),
        .pkgs = try pkgs_list.toOwnedSlice(alloc),
        .databases = try databases_list.toOwnedSlice(alloc),
        .inputs = inputs_list,
        .outputs = outputs_list,
        .keep = pipeline.keep,
        .second_instance = pipeline.second_instance,
        .memory_max = pipeline.memory_max,
        .memory_high = pipeline.memory_high,
        .cpu_quota = pipeline.cpu_quota,
        .tasks_max = pipeline.tasks_max,
        .io_weight = pipeline.io_weight,
        .timeout = pipeline.timeout,
    };
}
