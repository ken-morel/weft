const std = @import("std");
const log = std.log.scoped;

const Task = @import("../daemon/Task.zig");
const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const Connection = @import("../wire/Connection.zig");
const Identity = @import("../wire/Identity.zig");
const Client = @import("Client.zig");
const client_remote = @import("Remote.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Fetcher = @import("Fetcher.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");
const src = @import("src.zig");
const View = @import("View.zig");

pub fn run_deployment(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: *const ClientInstall,
    deployment: *Deployment,
    env: ?*std.process.Environ.Map,
) !void {
    const l = log(.runner);
    l.info("Running deployment {s}", .{&deployment.id.to_string()});

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const remotes = try client_remote.resolve_remotes_leaky(gpa, alloc, io, deployment.config, inst, project);
    const identity = inst.identity;

    var depl_buf = deployment.id.to_string();
    var view: View = .init(gpa, term, &depl_buf);
    defer view.deinit();

    var depl: std.Io.Mutex = .init;

    const clients: *Client.Manager = try .create(gpa, project, identity, env);
    defer clients.destroy(io);

    var fetcher: Fetcher = .{
        .gpa = gpa,
        .dep = deployment,
        .depl = &depl,
        .project = &project,
        .remotes = remotes,
        .term = term,
        .view = &view,
        .clients = clients,
    };
    defer fetcher.deinit(io);

    var group: std.Io.Group = .init;
    errdefer {
        view.update(io) catch {};
        l.err("Deployment {d} failed", .{deployment.id});
        group.await(io) catch {};
    }

    const log_buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(log_buffer);

    var poll_arena: std.heap.ArenaAllocator = .init(gpa);
    defer poll_arena.deinit();

    while (true) : (try std.Io.sleep(io, .fromSeconds(2), .awake)) {
        try depl.lock(io);
        defer depl.unlock(io);
        if (deployment.completed() and fetcher.is_idle(io))
            break;

        if (view.has_error(io) and deployment.running.len == 0) {
            try deployment.save(io, project);
            l.err("Error during deployment", .{});
            try std.Io.sleep(io, .fromSeconds(1), .awake);
            try view.update(io);
            return error.DeploymentFailed;
        }

        while (try deployment.next_step(term)) |step| {
            const remote = for (remotes) |*remote| {
                if (std.mem.eql(u8, remote.name, step.remote))
                    break remote;
            } else return error.InvalidRemote;

            const pipeline = deployment.config.get_pipeline(step.pipeline) orelse
                return error.InvalidPipeline;

            if (!pipeline.matches_remote(remote.*)) {
                l.err("pipeline '{s}' cannot run on remote '{s}' (does not match .on)", .{ pipeline.name, remote.name });
                return error.InvalidRemote;
            }

            try view.set_task(io, remote.name, pipeline.name, .{ .status = .preparing });
            try deployment.add_running(gpa, step);
            _ = try spawn(
                io,
                &group,
                spawn_step,
                .{ gpa, io, &view, project, &depl, deployment, remote, pipeline, &fetcher, step },
            );
        }

        for (remotes) |*remote| {
            const remote_name = remote.name;
            var batch_tasks: std.ArrayList(proto.task.poll.Req) = .empty;
            defer batch_tasks.deinit(poll_arena.allocator());

            for (deployment.running) |step| {
                if (!std.mem.eql(u8, step.remote, remote_name))
                    continue;
                const step_task = view.get_task(
                    io,
                    step.remote,
                    step.pipeline,
                ) orelse continue;
                if (!step_task.is_active())
                    continue;

                try batch_tasks.append(poll_arena.allocator(), .{
                    .task = .{
                        .deployment = deployment.id,
                        .pipeline = step.pipeline,
                        .workspace = deployment.config.workspace,
                    },
                    .logs_offset = step_task.log_offset,
                });
            }

            if (batch_tasks.items.len == 0)
                continue;

            poll_remote(
                gpa,
                io,
                project,
                deployment,
                &view,
                remote,
                remote_name,
                &poll_arena,
                log_buffer,
                batch_tasks.items,
                clients,
                &fetcher,
            );
        }

        _ = poll_arena.reset(.retain_capacity);

        try view.update(io);
    }
    try group.await(io);
    try view.update(io);
    term.success("Deployment completed", .{});
}

fn poll_remote(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: Project,
    deployment: *Deployment,
    view: *View,
    remote: *const Remote,
    remote_name: []const u8,
    poll_arena: *std.heap.ArenaAllocator,
    log_buffer: []u8,
    batch: []const proto.task.poll.Req,
    clients: *Client.Manager,
    fetcher: ?*Fetcher,
) void {
    const alloc = poll_arena.allocator();
    const managed = clients.connect_str(io, remote.address) catch return;
    defer managed.release(io);
    const client = managed.inner;

    client.conn.send_object(log_buffer, proto.Request, .task_poll) catch return;

    poll_batch(
        gpa,
        io,
        project,
        deployment,
        view,
        remote_name,
        alloc,
        log_buffer,
        batch,
        client,
        fetcher,
    ) catch return;
}

fn poll_batch(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: Project,
    deployment: *Deployment,
    view: *View,
    remote_name: []const u8,
    alloc: std.mem.Allocator,
    log_buffer: []u8,
    batch: []const proto.task.poll.Req,
    client: *Client,
    fetcher: ?*Fetcher,
) !void {
    for (batch) |task|
        try client.conn.send_object(log_buffer, proto.task.poll.Req, task);
    try client.conn.send_object(log_buffer, proto.task.poll.Req, null);

    var count: usize = 0;
    while (count < batch.len) : (count += 1) {
        const res = try client.conn.recv_object(alloc, proto.Res(proto.task.poll.Res));
        const item = try res;
        const poll_res = item orelse break;

        const pipeline_name = poll_res.task.pipeline;
        if (poll_res.logs) |logs| {
            if (logs.data.len > 0)
                try view.print_logs(pipeline_name, logs.data);
            try view.set_task(io, remote_name, pipeline_name, .{ .log_offset = logs.end_offset });
        }

        if (poll_res.usage) |u|
            try view.set_task(io, remote_name, pipeline_name, .{
                .usage = .{
                    .cpu_usec = u.cpu_usec,
                    .memory_bytes = u.memory_bytes,
                    .now = std.Io.Clock.now(.real, io),
                },
            });

        try poll_item(
            gpa,
            io,
            project,
            deployment,
            view,
            fetcher,
            remote_name,
            pipeline_name,
            poll_res.status,
        );
    }
    if (client.conn.recv_object_buf(log_buffer, proto.Res(proto.task.poll.Res))) |res| {
        _ = res catch {};
    } else |_| {}
}

fn fail_step(
    gpa: std.mem.Allocator,
    io: std.Io,
    depl: *std.Io.Mutex,
    dep: *Deployment,
    view: *View,
    project: Project,
    step: Deployment.Step,
    msg: []const u8,
) void {
    depl.lock(io) catch return;
    defer depl.unlock(io);
    dep.remove_running(gpa, step.remote, step.pipeline);
    view.set_task(io, step.remote, step.pipeline, .{ .status = .failed, .err = msg }) catch {};
    dep.save(io, project) catch {};
}

fn poll_item(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: Project,
    deployment: *Deployment,
    view: *View,
    fetcher: ?*Fetcher,
    remote_name: []const u8,
    pipeline_name: []const u8,
    status: proto.task.poll.Status,
) !void {
    if (status) |s| switch (s) {
        .preparing, .running, .harvesting, .frozen => {
            try view.set_task(io, remote_name, pipeline_name, .{ .status = s });
            return;
        },
        .done => {
            deployment.remove_running(gpa, remote_name, pipeline_name);
            const pipeline = deployment.config.get_pipeline(pipeline_name);
            if (pipeline) |p| {
                const is_target = for (deployment.targets) |target| {
                    if (std.mem.eql(u8, target.pipeline, pipeline_name))
                        break true;
                } else false;

                for (p.out orelse &.{p.name}) |output| {
                    try deployment.add_artifact(gpa, .{
                        .remote = remote_name,
                        .pipeline = p.name,
                        .name = output,
                    });

                    if (fetcher) |f|
                        if (is_target and !std.mem.eql(u8, remote_name, "local"))
                            try f.spawn_fetch(io, output);
                }
            }

            try view.set_task(io, remote_name, pipeline_name, .{ .status = .done });
        },
        .failed => {
            const code = 1; //TODO: restore this when actually fetching the code
            deployment.remove_running(gpa, remote_name, pipeline_name);
            const err_msg = try gpa.print("task failed with exit code {d}", .{code});
            defer gpa.free(err_msg);
            try view.set_task(io, remote_name, pipeline_name, .{ .status = .failed, .err = err_msg });

            if (deployment.config.get_pipeline(pipeline_name)) |pipeline|
                try deployment.add_failed(gpa, .{
                    .retries_left = pipeline.max_retries,
                    .remote = remote_name,
                    .pipeline = pipeline.name,
                    .status = .{ .term = code },
                });
        },
        .skipped => {
            deployment.remove_running(gpa, remote_name, pipeline_name);
            try view.set_task(io, remote_name, pipeline_name, .{ .status = .skipped });
        },
        .killed => {
            deployment.remove_running(gpa, remote_name, pipeline_name);
            try view.set_task(io, remote_name, pipeline_name, .{ .status = .killed });

            if (deployment.config.get_pipeline(pipeline_name)) |pipeline|
                try deployment.add_failed(gpa, .{
                    .retries_left = pipeline.max_retries,
                    .remote = remote_name,
                    .pipeline = pipeline.name,
                    .status = .stopped,
                });
        },
    } else {
        if (view.get_task(io, remote_name, pipeline_name)) |t|
            if (t.status == .preparing)
                return; // spawn still in flight; keep polling

        deployment.remove_running(gpa, remote_name, pipeline_name);
        try view.set_task(io, remote_name, pipeline_name, .{ .status = .failed, .err = "task not found on remote" });
        if (deployment.config.get_pipeline(pipeline_name)) |pipeline|
            try deployment.add_failed(gpa, .{
                .retries_left = 0,
                .remote = remote_name,
                .pipeline = pipeline.name,
                .status = .not_found,
            });
    }
    try deployment.save(io, project);
}

pub fn run_task(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: *const ClientInstall,
    deployment: *Deployment,
    step: Deployment.Step,
    env: ?*std.process.Environ.Map,
) !void {
    const l = log(.runner);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const remotes = try client_remote.resolve_remotes_leaky(gpa, alloc, io, deployment.config, inst, project);
    const identity = inst.identity;

    const remote = for (remotes) |*remote| {
        if (std.mem.eql(u8, remote.name, step.remote))
            break remote;
    } else return error.InvalidRemote;

    const pipeline = deployment.config.get_pipeline(step.pipeline) orelse
        return error.InvalidPipeline;

    if (!pipeline.matches_remote(remote.*)) {
        l.err("pipeline '{s}' cannot run on remote '{s}' (does not match .on)", .{ pipeline.name, remote.name });
        return error.InvalidRemote;
    }

    const res_status = try deployment.resolve_pipeline(term, step.pipeline, 0);
    const reports_need = switch (res_status) {
        .needs, .needs_failed, .waits => true,
        else => false,
    };

    if (reports_need) {
        var missing_artifact: ?[]const u8 = null;
        for (pipeline.in) |in| {
            if (Weft.is_source_artifact(in))
                continue
            else if (deployment.get_artifact(in) != null)
                continue
            else {
                const art_dir = project.artifact_dir_path(alloc, io, deployment.id, in) catch null;
                const on_disk = if (art_dir) |dir_path| disk_check: {
                    defer alloc.free(dir_path);
                    if (std.Io.Dir.cwd().access(io, dir_path, .{})) |_|
                        break :disk_check true
                    else |_|
                        break :disk_check false;
                } else false;

                if (on_disk) {
                    const prod = deployment.config.get_producer(in);
                    try deployment.add_artifact(alloc, .{
                        .remote = "local",
                        .pipeline = if (prod) |p|
                            p.name
                        else
                            in,
                        .name = in,
                    });
                } else {
                    missing_artifact = in;
                    break;
                }
            }
        }

        if (missing_artifact) |missing| {
            switch (res_status) {
                .needs => |needed| {
                    l.err("artifact '{s}' is missing; pipeline '{s}' requires pipeline '{s}' to be run first", .{ missing, step.pipeline, needed });
                    return error.MissingDependency;
                },
                .needs_failed => |needed| {
                    l.err("artifact '{s}' is missing; dependency pipeline '{s}' failed", .{ missing, needed });
                    return error.DependencyFailed;
                },
                .waits => |w| {
                    l.err("artifact '{s}' is missing; dependency pipeline '{s}' is still running", .{ missing, w });
                    return error.DependencyRunning;
                },
                else => {
                    l.err("required artifact '{s}' is missing for pipeline '{s}'", .{ missing, step.pipeline });
                    return error.MissingDependency;
                },
            }
        }
    }

    const is_in_targets = for (deployment.targets) |target| {
        if (std.mem.eql(u8, target.pipeline, step.pipeline))
            break true;
    } else false;
    if (!is_in_targets) {
        deployment.targets = try alloc.realloc(deployment.targets, deployment.targets.len + 1);
        deployment.targets[deployment.targets.len - 1] = step;
    }

    var depl_buf = deployment.id.to_string();
    var view: View = .init(gpa, term, &depl_buf);
    defer view.deinit();

    var depl: std.Io.Mutex = .init;

    const clients: *Client.Manager = try .create(gpa, project, identity, env);
    defer clients.destroy(io);

    var fetcher: Fetcher = .{
        .gpa = gpa,
        .dep = deployment,
        .depl = &depl,
        .project = &project,
        .remotes = remotes,
        .term = term,
        .view = &view,
        .clients = clients,
    };
    defer fetcher.deinit(io);

    var group: std.Io.Group = .init;
    errdefer group.await(io) catch {};
    errdefer deployment.save(io, project) catch {};

    try src.create_sources(alloc, io, term, inst, project, deployment);

    try view.set_task(io, remote.name, pipeline.name, .{ .status = .preparing });
    try deployment.add_running(gpa, step);
    _ = try spawn(
        io,
        &group,
        spawn_step,
        .{ gpa, io, &view, project, &depl, deployment, remote, pipeline, &fetcher, step },
    );

    const log_buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(log_buffer);

    var poll_arena: std.heap.ArenaAllocator = .init(gpa);
    defer poll_arena.deinit();

    while (true) : (try std.Io.sleep(io, .fromSeconds(2), .awake)) {
        try depl.lock(io);
        defer depl.unlock(io);

        const still_running = for (deployment.running) |running| {
            if (std.mem.eql(u8, running.remote, step.remote) and std.mem.eql(u8, running.pipeline, step.pipeline))
                break true;
        } else false;

        if (!still_running)
            break;

        const step_task = view.get_task(io, step.remote, step.pipeline) orelse break;
        if (!step_task.is_active())
            continue;

        const batch = [_]proto.task.poll.Req{.{
            .task = .{
                .deployment = deployment.id,
                .pipeline = step.pipeline,
                .workspace = deployment.config.workspace,
            },
            .logs_offset = step_task.log_offset,
        }};

        poll_remote(
            gpa,
            io,
            project,
            deployment,
            &view,
            remote,
            step.remote,
            &poll_arena,
            log_buffer,
            &batch,
            clients,
            &fetcher,
        );

        _ = poll_arena.reset(.retain_capacity);
        try view.update(io);
    }
    try group.await(io);
    fetcher.await_all(io) catch |err|
        l.warn("error waiting for artifact transfers: {any}", .{err});
    try view.update(io);

    const final_task = view.get_task(io, step.remote, step.pipeline) orelse {
        l.err("task {s} was never registered", .{step.pipeline});
        return error.DeploymentFailed;
    };

    switch (final_task.status) {
        .done => {
            try deployment.save(io, project);
            term.success("Task {s} completed", .{step.pipeline});
        },
        .skipped => term.success("Task {s} skipped", .{step.pipeline}),
        .killed => {
            l.err("Task {s} stopped", .{step.pipeline});
            return error.DeploymentFailed;
        },
        else => {
            l.err("Task {s} failed (status: {s})", .{ step.pipeline, @tagName(final_task.status) });
            return error.DeploymentFailed;
        },
    }
}

pub fn spawn_step(
    gpa: std.mem.Allocator,
    io: std.Io,
    view: *View,
    project: Project,
    depl: *std.Io.Mutex,
    dep: *Deployment,
    remote: *const Remote,
    pipeline: *const Weft.Pipeline,
    fetcher: *Fetcher,
    step: Deployment.Step,
) !void {
    const l = log(.spawn);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    errdefer fail_step(gpa, io, depl, dep, view, project, step, "failed to spawn task");

    if (!dep.config.has_mode(step.mode))
        return error.InvalidMode;

    if (!pipeline.matches_remote(remote.*)) {
        l.err("pipeline '{s}' cannot run on remote '{s}' (does not match .on)", .{ pipeline.name, remote.name });
        return error.InvalidRemote;
    }

    const script_content = switch (pipeline.run orelse @as(Weft.Pipeline.Run, .{ .file = pipeline.name })) {
        .script => |script_str| inline_script: {
            if (script_str.len == 0) {
                l.err("pipeline '{s}': .run.script cannot be empty", .{pipeline.name});
                return error.EmptyScript;
            }
            if (!std.mem.startsWith(u8, script_str, "#!")) {
                l.err("pipeline '{s}': .run.script must start with a '#!' shebang", .{pipeline.name});
                return error.MissingShebang;
            }
            break :inline_script script_str;
        },
        .file => |script_name| file_script: {
            const script_path = try project.locate_script(gpa, io, script_name) orelse {
                l.err("weft folder not found, cannot run pipeline {s}", .{pipeline.name});
                return error.FileNotFound;
            };
            defer gpa.free(script_path);

            break :file_script project.dir.readFileAlloc(io, script_path, gpa, .limited(60 * 1024)) catch |err| {
                if (err == error.FileNotFound)
                    l.err("Script {s} does not exist, cannot run pipeline {s}", .{ script_path, pipeline.name })
                else if (err == error.FileTooBig)
                    l.err("Script {s} exceeds 60KB limit for pipeline {s}", .{ script_path, pipeline.name });
                return err;
            };
        },
        .nothing => null,
    };
    defer if (script_content) |s|
        gpa.free(s);

    const spec: Task.Spec = try .resolve_leaky(
        gpa,
        alloc,
        io,
        &dep.config,
        pipeline,
        dep.id,
        step.mode,
        project.env,
        script_content,
    );

    for (spec.inputs) |input|
        try fetcher.upload(io, remote, input);

    const buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(buffer);

    try view.set_task(io, step.remote, step.pipeline, .{ .status = .preparing });

    spawn_task: {
        const managed = try fetcher.clients.connect_str(io, remote.address);
        defer managed.release(io);
        const client = managed.inner;

        try client.conn.send_object(buffer, proto.Request, .task_spawn);
        try client.conn.send_object(buffer, proto.task.spawn.Req, .{
            .spec = spec,
        });

        const res = client.conn.recv_object_buf(
            buffer,
            proto.Res(proto.task.spawn.Res),
        ) catch |err| {
            fail_step(gpa, io, depl, dep, view, project, step, @errorName(err));
            return;
        };

        if (res) |_| {
            try view.set_task(io, step.remote, step.pipeline, .{ .status = .running });
        } else |err| {
            fail_step(gpa, io, depl, dep, view, project, step, @errorName(err));
            return;
        }
        break :spawn_task;
    }
}
