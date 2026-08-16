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
        while (try deployment.next()) |next_step|
            try spawn_next_step(
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
}

pub fn spawn_next_step(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    deployment: *Deployment,
    step: Deployment.NextStep,
) !void {
    try term.printlnf("spawning deployment step: {s} on {s}", .{ step.pipeline, step.remote });
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const remote = (try inst.get_remote(&arena, io, step.remote)) orelse {
        try term.err("Invalid remote: {s}", .{step.remote});
        return error.InvalidRemote;
    };
    const pipeline = deployment.service.get_pipeline(step.pipeline) orelse return error.InvalidPipeline;

    var all_inputs: [pipeline.inputs.len]?ids.ArtifactId = undefined;
    for (pipeline.inputs, 0..) |input, i| {
        switch (input) {
            .src => all_inputs[i] = null,
            .artifact => |art_input| {
                var found = false;
                for (deployment.artifacts) |artifact| {
                    if (art_input.matches(artifact) and !artifact.consumed) {
                        all_inputs[i] = .{
                            .idx = artifact.num,
                            .task = .{
                                .pipeline = pipeline.name,
                                .deployment = .from_deployment(deployment.*),
                            },
                        };
                        found = true;
                    }
                }
                if (!found)
                    return error.MissingStepArgument;
            },
        }
    }
    try uploader.upload_artifacts(alloc, io, term, project, inst, deployment, &all_inputs);

    var client = try Client.connect(alloc, io, remote);
    try term.printlnf("Connected to remote {s} at {any}", .{ remote.name, remote.address });
    defer client.destroy(alloc, io);
    try term.printlnf("Sending request", .{});
    try client.conn.send(.{ .request = .task_create });
    try term.printlnf("  .. request data ", .{});
    try client.conn.send(.{
        .task_id = .{
            .deployment = .from_deployment(deployment.*),
            .pipeline = step.pipeline,
        },
    });
    try term.printlnf("  .. pipeline ", .{});
    try client.conn.send(.{
        .pipeline = pipeline.*,
    });
    try term.printlnf("waiting for response... ", .{});
    {
        var msg_arena: std.heap.ArenaAllocator = .init(alloc);
        defer msg_arena.deinit();
        const msg = try client.conn.recv(&msg_arena);
        try term.printlnf("Recived message: {any}", .{msg});
    }
}
