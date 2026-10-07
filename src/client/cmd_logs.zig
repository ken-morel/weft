const std = @import("std");
const log = std.log.scoped;

const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const format_bytes = @import("../util/sizes.zig").format_bytes;
const Connection = @import("../wire/Connection.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: Project,
    inst: ClientInstall,
    pipeline_name: []const u8,
    deployment_spec: ?[]const u8,
    remote_spec: ?[]const u8,
) !void {
    const l = log(.follow);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const dep_id = if (deployment_spec) |dep_str|
        project.find_deployment_id(io, dep_str) catch |err| {
            l.err("deployment '{s}' not found or ambiguous: {any}", .{ dep_str, err });
            return error.InvalidDeploymentId;
        }
    else
        try project.latest_deployment_id(io) orelse {
            l.err("no deployments found in .weft", .{});
            return error.NoDeployments;
        };

    var deployment = project.load_deployment_leaky(alloc, io, dep_id) catch |err| {
        l.err("failed to load deployment: {any}", .{err});
        return err;
    };

    const remotes = try inst.get_remotes_leaky(gpa, alloc, io);

    _ = deployment.config.get_pipeline(pipeline_name) orelse {
        l.err("pipeline '{s}' not found in deployment {s}", .{ pipeline_name, &deployment.id.to_string() });
        return error.InvalidPipeline;
    };

    const remote_name = if (remote_spec) |s|
        s
    else for (deployment.artifacts) |art| {
        if (std.mem.eql(u8, art.pipeline, pipeline_name))
            break art.remote;
    } else for (deployment.running) |run_| {
        if (std.mem.eql(u8, run_.pipeline, pipeline_name))
            break run_.remote;
    } else {
        l.err("Couldn't find where pipeline {s} did ran", .{pipeline_name});
        return error.RemoteNotFound;
    };

    const remote: *const Remote = for (remotes) |*rem| {
        if (std.mem.eql(u8, rem.get_name(), remote_name))
            break rem;
    } else {
        l.err("remote '{s}' not found", .{remote_name});
        return error.InvalidRemote;
    };

    const key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ remote_name, pipeline_name });

    const task_id: proto.task.Id = .{
        .workspace = deployment.config.workspace,
        .deployment = deployment.id,
        .pipeline = pipeline_name,
    };

    var offset: u64 = 0;

    const buffer = try alloc.alloc(u8, Connection.max_packet_size);

    var client = Client.connect(
        alloc,
        io,
        try remote.get_address(),
        &try remote.get_token(),
    ) catch |e| {
        l.err("connection to remote '{s}' failed: {any}", .{ remote_name, e });
        return e;
    };
    defer client.destroy(alloc, io);

    var req_arena: std.heap.ArenaAllocator = .init(gpa);
    defer req_arena.deinit();
    const req_alloc = req_arena.allocator();

    var status: proto.task.poll.Status = .not_found;
    const stdout: std.Io.File = .stdout();

    try stdout.writeStreamingAll(io, try std.fmt.allocPrint(alloc, "{s} {s}", .{ "{", key }));

    while (true) : (_ = req_arena.reset(.retain_capacity)) {
        try client.conn.send_object(buffer, proto.Request, .task_poll);
        try client.conn.send_object(buffer, proto.task.poll.Req, .{
            .header = .{
                .tasks = &.{.{
                    .task = task_id,
                    .logs_offset = offset,
                }},
            },
        });

        const res = client.conn.recv_object(
            req_alloc,
            proto.Res(proto.task.poll.Res),
        ) catch |e| {
            l.err("failed to receive poll reply: {any}", .{e});
            return e;
        } catch |e| {
            l.err("poll error from remote: {any}", .{e});
            return e;
        };

        switch (res) {
            .item => |item| {
                if (item.logs) |logs| {
                    try stdout.writeStreamingAll(io, logs.data);
                    offset = logs.end_offset;
                }
                status = item.status;
            },
            .footer => break,
        }

        try std.Io.sleep(io, .fromSeconds(2), .awake);
    }
    switch (status) {
        .success => try stdout.writeStreamingAll(
            io,
            try std.fmt.allocPrint(alloc, "{s} {s}", .{ "}", key }),
        ),
        .failed => |c| try stdout.writeStreamingAll(
            io,
            try std.fmt.allocPrint(alloc, "#.faied {s} code {d}", .{ key, c }),
        ),
        .skipped, .stopped => try stdout.writeStreamingAll(
            io,
            try std.fmt.allocPrint(alloc, "#{any} {s} ", .{ status, key }),
        ),
        .not_found => {
            l.err("Task {s} not found", .{key});
            return error.TaskNotFound;
        },
        .running => {
            l.err("Task still running", .{});
            return error.TaskStillRunning;
        },
    }
}
