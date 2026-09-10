const std = @import("std");

const Deployment = @import("../Deployment.zig");
const ClientInstall = @import("../ClientInstall.zig");
const Project = @import("../Project.zig");
const Term = @import("../Term.zig");
const Client = @import("../Client.zig");
const ids = @import("../ids.zig");
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

    const client = try Client.connect(alloc, io, remote);
    defer client.destroy(alloc, io);

    try client.conn.send(.{ .request = .task_spawn });

    try client.conn.send(.{
        .task_spec = .{
            .deployment = deployment.uuid,
            .env = deployment.env,
            .pipline = pipeline.*,
            .service = deployment.service.name,
            .workspace = deployment.service.workspace,
        },
    });
    const script_path = try std.fs.path.join(alloc, &.{
        "bin",
        pipeline.script,
    });
    defer alloc.free(script_path);

    const script = try project.dir.openFile(io, script_path, .{});

    var buffer = try alloc.alloc(u8, Client.Connection.packet_size - 10);

    while (true) {
        const size = script.readStreaming(io, &.{buffer}) catch |err|
            if (err == error.EndOfStream)
                break
            else
                return err;
        try client.conn.send(.{ .raw = buffer[0..size] });
    }
    try client.conn.send(.end);

    switch (try client.conn.recv_ref(null)) {
        .ok => {},
        .err => |err| {
            try term.err("Remote error: {any}", .{err});
            return err;
        },
        else => return error.SyntaxError,
    }

    deployment.running = try alloc.realloc(deployment.running, deployment.running.len + 1);
    const item = &deployment.running[deployment.running.len - 1];
    item.* = step;
    try term.success("Spawned task succesfully", .{});
}
