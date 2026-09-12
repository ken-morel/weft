const std = @import("std");

const Client = @import("../Client.zig");
const ClientInstall = @import("../ClientInstall.zig");
const Connection = @import("../Connection.zig");
const Deployment = @import("../Deployment.zig");
const Project = @import("../Project.zig");
const proto = @import("../proto.zig");
const Term = @import("../Term.zig");
const uploader = @import("uploader.zig");

pub fn run_deployment(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    deployment: *Deployment,
) !void {
    while (!deployment.completed()) {
        while (try deployment.next_step()) |next_step|
            try spawn_step(
                alloc,
                io,
                term,
                project,
                inst,
                deployment,
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
    inst: ClientInstall,
    deployment: *Deployment,
    step: Deployment.Step,
) !void {
    var buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(buffer);
    try term.info("spawning deployment step: {s} on {s}", .{ step.pipeline, step.remote });
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const remote = (try inst.get_remote(arena.allocator(), io, step.remote)) orelse {
        try term.err("invalid remote: {s}", .{step.remote});
        return error.InvalidRemote;
    };
    const pipeline = deployment.service.get_pipeline(step.pipeline) orelse {
        try term.err("invalid pipeline: {s}", .{step.pipeline});
        return error.InvalidPipeline;
    };

    try uploader.send_required_artifacts(alloc, io, term, inst, project, deployment.*, pipeline.*, remote);

    const client = try Client.connect(alloc, io, remote.address, &remote.token);
    defer client.destroy(alloc, io);

    try client.conn.send_object(buffer, proto.task.spawn.Req{
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
