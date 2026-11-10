const std = @import("std");
const log = std.log.scoped;

const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const format_bytes = @import("../util/sizes.zig").format_bytes;
const Connection = @import("../wire/Connection.zig");
const Client = @import("Client.zig");
const client_remote = @import("Remote.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");
const Step = @import("Step.zig");

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: Project,
    inst: *const ClientInstall,
    step: Step,
    deployment_spec: ?[]const u8,
    env: ?*std.process.Environ.Map,
) !void {
    const l = log(.follow);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const dep_id = try project.resolve_deployment_id(io, deployment_spec);

    var deployment = project.load_deployment_leaky(gpa, alloc, io, dep_id) catch |err| {
        l.err("failed to load deployment: {any}", .{err});
        return err;
    };

    const remotes = try client_remote.resolve_remotes_leaky(gpa, alloc, io, deployment.config, inst, project);

    const pipeline_name = step.pipeline;
    const pipeline = deployment.config.get_pipeline(pipeline_name) orelse {
        l.err("pipeline '{s}' not found in deployment {s}", .{ pipeline_name, &deployment.id.to_string() });
        return error.InvalidPipeline;
    };

    const remote_name = if (std.mem.eql(u8, step.remote, "_"))
        for (deployment.artifacts) |art| {
            if (std.mem.eql(u8, art.pipeline, pipeline_name))
                break art.remote;
        } else for (deployment.running) |run_| {
            if (std.mem.eql(u8, run_.pipeline, pipeline_name))
                break run_.remote;
        } else deployment.config.select_remote_for(pipeline, null) orelse "local"
    else
        step.remote;

    const remote: *const Remote = for (remotes) |*rem| {
        if (std.mem.eql(u8, rem.name, remote_name))
            break rem;
    } else {
        l.err("remote '{s}' not found", .{remote_name});
        return error.InvalidRemote;
    };

    const key = try alloc.print("{s}.{s}", .{ remote_name, pipeline_name });

    const task_id: proto.task.Id = .{
        .workspace = deployment.config.workspace,
        .deployment = deployment.id,
        .pipeline = pipeline_name,
    };

    var offset: u64 = 0;

    const buffer = try alloc.alloc(u8, Connection.max_packet_size);

    var clients: *Client.Manager = try .create(alloc, project, inst.identity, env);
    defer clients.destroy(io);

    var managed = clients.connect_str(
        io,
        remote.address,
    ) catch |e| {
        l.err("connection to remote '{s}' failed: {any}", .{ remote_name, e });
        return e;
    };
    defer managed.release(io);
    const client = managed.inner;

    var req_arena: std.heap.ArenaAllocator = .init(gpa);
    defer req_arena.deinit();
    const req_alloc = req_arena.allocator();

    var status: proto.task.poll.Status = null;
    const stdout: std.Io.File = .stdout();

    try stdout.writeStreamingAll(io, try alloc.print("{s} {s}", .{ "{", key }));

    try client.conn.send_object(buffer, proto.Request, .task_poll);

    while (true) : (_ = req_arena.reset(.retain_capacity)) {
        try client.conn.send_object(buffer, proto.task.poll.Req, .{
            .task = task_id,
            .logs_offset = offset,
        });

        const res = client.conn.recv_object(
            req_alloc,
            proto.Res(proto.task.poll.Res),
        ) catch |e| {
            l.err("failed to receive poll reply: {any}", .{e});
            return e;
        };

        const data = res catch |e| {
            l.err("poll error from remote: {any}", .{e});
            return e;
        };

        var has_more_logs = false;
        if (data) |item| {
            if (item.logs) |logs| {
                try stdout.writeStreamingAll(io, logs.data);
                offset = logs.end_offset;
                if (logs.data.len > 0)
                    has_more_logs = true;
            }
            status = item.status;
            if (status) |s| switch (s) {
                .done, .failed, .killed, .skipped, .frozen => {
                    if (!has_more_logs)
                        break;
                },
                else => {},
            };
        } else break;

        if (!has_more_logs)
            try std.Io.sleep(io, .fromSeconds(2), .awake);
    }

    if (status) |s| switch (s) {
        .harvesting, .done, .skipped => try stdout.writeStreamingAll(
            io,
            try alloc.print("{s} {s}", .{ "}", key }),
        ),
        .failed => try stdout.writeStreamingAll(
            io,
            try alloc.print("#.failed {s}", .{key}),
        ),
        .killed => try stdout.writeStreamingAll(
            io,
            try alloc.print("#.killed {s}", .{key}),
        ),

        .running, .preparing => {
            l.err("Task still running", .{});
            return error.TaskStillRunning;
        },
        .frozen => try stdout.writeStreamingAll(
            io,
            try alloc.print("- {s}", .{key}),
        ),
    } else {
        l.err("Task {s} not found", .{key});
        return error.TaskNotFound;
    }
}
