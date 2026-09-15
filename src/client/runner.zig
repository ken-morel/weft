const std = @import("std");

const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Connection = @import("../wire/Connection.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const proto = @import("../wire/proto.zig");
const Remote = @import("Remote.zig");
const Term = @import("../domain/Term.zig");
const uploader = @import("uploader.zig");

pub fn run_deployment(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    deployment: *Deployment,
) !void {
    const remotes = try inst.get_remotes(alloc, io, term);
    while (!deployment.completed()) {
        while (try deployment.next_step()) |next_step|
            try spawn_step(
                alloc,
                io,
                term,
                project,
                deployment,
                remotes,
                next_step,
            );

        break;
        // wait for event
    }
    try term.success("Deployment completed", .{});
}
pub fn spawn_step(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    deployment: *Deployment,
    remotes: []const Remote,
    step: Deployment.Step,
) !void {
    var buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(buffer);
    try term.info("spawning deployment step: {s} on {s}", .{ step.pipeline, step.remote });
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const remote: *const Remote = remote: for (remotes) |*remote| {
        if (std.mem.eql(u8, remote.get_name(), step.remote))
            break :remote remote;
    } else return error.InvalidRemote;
    const pipeline = deployment.service.get_pipeline(step.pipeline) orelse {
        try term.err("invalid pipeline: {s}", .{step.pipeline});
        return error.InvalidPipeline;
    };

    try uploader.send_required_artifacts(alloc, io, term, project, deployment.*, pipeline.*, remotes, remote);

    const client = try Client.connect(alloc, io, try remote.get_address(), &try remote.get_token());
    defer client.destroy(alloc, io);

    try client.conn.send_object(buffer, proto.Request, .task_spawn);
    try client.conn.send_object(buffer, proto.task.spawn.Req, .{
        .task = .{
            .deployment = deployment.uuid,
            .env = deployment.env,
            .pipeline = pipeline.name,
            .service = deployment.service.name,
            .workspace = deployment.service.workspace,
        },
        .pipeline = pipeline.*,
    });

    const script_path = try std.fs.path.join(alloc, &.{
        "bin",
        pipeline.script,
    });
    defer alloc.free(script_path);

    const script = try project.dir.openFile(io, script_path, .{});
    defer script.close(io);

    while (true) {
        const size = script.readStreaming(io, &.{buffer[1..]}) catch |err|
            if (err == error.EndOfStream)
                break
            else
                return err;
        buffer[0] = proto.task.spawn.data;
        try client.conn.send(buffer[0 .. size + 1]);
    }
    buffer[0] = proto.task.spawn.end;
    try client.conn.send(buffer[0..1]);

    const reply = try client.conn.recv_object_buf(buffer, anyerror!proto.task.spawn.Res);
    if (reply) |_| {
        deployment.running = try alloc.realloc(deployment.running, deployment.running.len + 1);
        const item = &deployment.running[deployment.running.len - 1];
        item.* = step;
        try term.success("Spawned task succesfully", .{});
    } else |err| {
        try term.err("Remote error: {any}", .{err});
        return err;
    }
}
