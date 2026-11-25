const std = @import("std");
const log = std.log.scoped;

const proto = @import("../domain/proto.zig");
const Task = @import("../domain/Task.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const Connection = @import("../wire/Connection.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");
const View = @import("View.zig");

fn ensure_packages(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    config: Weft,
    name: []const u8,
    mode: []const u8,
    pkgs: []const []const u8,
    host_env: ?*std.process.Environ.Map,
) !void {
    const l = log(.env);
    if (pkgs.len == 0)
        return;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cwd: std.Io.Dir = .cwd();
    const missing = pkg: for (pkgs) |pkg| {
        const store_path = try alloc.print("/nix/store/{s}", .{pkg});
        cwd.access(io, store_path, .{}) catch break :pkg true;
    } else false;

    if (!missing)
        return;

    const remotes = try Remote.resolve_remotes_leaky(gpa, alloc, io, config, inst, project);
    const local_remote = Remote.find(remotes, "local") orelse blk: {
        const inst_remotes = try Remote.resolve_remotes_leaky(gpa, alloc, io, null, inst, project);
        break :blk Remote.find(inst_remotes, "local") orelse {
            l.err("local remote not configured", .{});
            return error.InvalidRemote;
        };
    };

    const dep_id: Deployment.Id = try .now(io);
    const task_id: Task.Id = .{
        .workspace = "weft",
        .deployment = dep_id,
        .pipeline = name,
    };

    const clients: *Client.Manager = try .create(gpa, inst.identity, host_env);
    defer clients.destroy(io);
    clients.inst = inst;
    clients.project = project;

    const managed = clients.connect_blocking(
        io,
        local_remote.address,
    ) catch |err| {
        l.err("failed to connect to local daemon: {any}", .{err});
        return err;
    };
    defer managed.release(io);
    const client = managed.inner;

    const buffer = try alloc.alloc(u8, Connection.max_packet_size);
    const spec: Task.Spec = .{
        .id = task_id,
        .script = null,
        .pkgs = pkgs,
        .mode = mode,
        .tune = .{},
        .retention = config.retention,
    };

    var depl_buf = dep_id.to_string();
    var view: View = .init(gpa, term, &depl_buf);
    defer view.deinit();

    try view.set_task(io, "local", name, mode, .{ .status = .preparing });

    try client.conn.send_object(buffer, proto.Request, .task_spawn);
    try client.conn.send_object(buffer, proto.task.spawn.Req, .{
        .spec = spec,
    });
    _ = try try client.conn.recv_object_buf(buffer, proto.R(proto.task.spawn.Res));

    var req_arena: std.heap.ArenaAllocator = .init(gpa);
    defer req_arena.deinit();
    const req_alloc = req_arena.allocator();

    var offset: u64 = 0;
    try client.conn.send_object(buffer, proto.Request, .task_poll);

    const final_status: ?Task.Status = while (true) : (_ = req_arena.reset(.retain_capacity)) {
        try client.conn.send_object(buffer, proto.task.poll.Req, .{
            .task = task_id,
            .logs_offset = offset,
        });

        const res = try client.conn.recv_object(req_alloc, proto.R(proto.task.poll.Res));
        const item = try res orelse break null;

        const more = if (item.logs) |logs| logs: {
            if (logs.data.len > 0)
                try view.print_logs(name, logs.data);
            offset = logs.end_offset;
            try view.set_task(io, "local", name, mode, .{ .log_offset = logs.end_offset });
            break :logs logs.more;
        } else 0;

        if (more > 0)
            continue;

        if (item.status) |s| {
            try view.set_task(io, "local", name, mode, .{ .status = s });
            switch (s) {
                .done, .skipped, .failed, .killed, .frozen => break s,
                else => {},
            }
        }

        try std.Io.sleep(io, .fromMilliseconds(200), .awake);
    };

    try client.conn.send_object(buffer, proto.task.poll.Req, null);
    if (client.conn.recv_object_buf(buffer, proto.R(proto.task.poll.Res))) |res| {
        _ = res catch {};
    } else |_| {}

    try view.update(io);
    try term.flush();

    if (final_status) |f|
        if (f != .done)
            return error.EnvSetupFailed;
}

fn resolve_envs_leaky(
    gpa: std.mem.Allocator,
    ara: std.mem.Allocator,
    io: std.Io,
    config: Weft,
    project: Project,
    mode: []const u8,
    names_spec: []const u8,
) !Task.Spec.Env {
    const l = log(.env);
    var pkgs: std.ArrayList([]const u8) = .empty;
    defer pkgs.deinit(ara);

    var vars_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer vars_map.deinit(ara);

    var iter = std.mem.splitScalar(u8, names_spec, ',');
    while (iter.next()) |env_name| {
        if (env_name.len == 0) {
            l.err("empty environment name in '{s}'", .{names_spec});
            return error.InvalidArgument;
        }

        const target_env: Weft.Env = if (config.get_pipeline(env_name)) |pipeline|
            pipeline.environ()
        else if (config.get_environment(env_name)) |env_cfg|
            env_cfg.*
        else {
            l.err("pipeline or environment '{s}' not found in weft/weft.zon", .{env_name});
            return error.EnvironNotFound;
        };

        const resolved = try Task.Spec.resolve_env_leaky(
            gpa,
            ara,
            io,
            mode,
            config.environments,
            project.env,
            target_env,
        );

        for (resolved.pkgs) |pkg|
            for (pkgs.items) |existing| {
                if (std.mem.eql(u8, existing, pkg))
                    break;
            } else try pkgs.append(ara, pkg);

        for (resolved.vars) |kv|
            try vars_map.put(ara, kv.@"0", kv.@"1");
    }

    const vars = try ara.alloc(struct { []const u8, []const u8 }, vars_map.size);
    var vars_iter = vars_map.iterator();
    var i: usize = 0;
    while (vars_iter.next()) |entry| : (i += 1) {
        vars[i].@"0" = entry.key_ptr.*;
        vars[i].@"1" = entry.value_ptr.*;
    }

    return .{
        .pkgs = try pkgs.toOwnedSlice(ara),
        .vars = vars,
    };
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    env_spec: []const u8,
    cmds: [][]const u8,
    host_env: ?*std.process.Environ.Map,
) !void {
    const l = log(.env);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const mode, const names_spec = if (std.mem.findScalar(u8, env_spec, ':')) |sep|
        .{ env_spec[0..sep], env_spec[sep + 1 ..] }
    else
        .{ "default", env_spec };

    if (mode.len == 0 or names_spec.len == 0) {
        l.err("invalid environment specifier '{s}'", .{env_spec});
        return error.InvalidArgument;
    }

    const config = try project.get_config_leaky(alloc, io);
    if (!config.has_mode(mode)) {
        l.err("mode '{s}' not found in weft/weft.zon", .{mode});
        return error.InvalidMode;
    }

    const resolved = try resolve_envs_leaky(
        gpa,
        alloc,
        io,
        config,
        project,
        mode,
        names_spec,
    );

    try ensure_packages(
        gpa,
        io,
        term,
        project,
        inst,
        config,
        names_spec,
        mode,
        resolved.pkgs,
        host_env,
    );

    var child_env: std.process.Environ.Map = .init(gpa);
    defer child_env.deinit();

    if (host_env) |he| {
        var iter = he.iterator();
        while (iter.next()) |entry|
            try child_env.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    const base_path = child_env.get("PATH") orelse "/usr/bin:/bin";
    try resolved.apply(gpa, &child_env, base_path, mode, config.workspace);
    try child_env.put("WEFT_ENV", names_spec);

    const shell = child_env.get("SHELL") orelse "/bin/sh";
    const argv: []const []const u8 = if (cmds.len > 0)
        cmds
    else
        &.{shell};

    const argv_env = try gpa.alloc([]const u8, argv.len + 1);
    defer gpa.free(argv_env);
    @memcpy(argv_env[1..], argv);
    argv_env[0] = "env";

    l.info("running command", .{});
    var child = try std.process.spawn(io, .{
        .argv = argv_env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &child_env,
    });
    const wait_term = try child.wait(io);
    switch (wait_term) {
        .exited => |code| if (code != 0)
            std.process.exit(code),
        .signal => |sig| std.process.exit(128 + @as(u8, @truncate(@backingInt(sig)))),
        else => std.process.exit(1),
    }
}
