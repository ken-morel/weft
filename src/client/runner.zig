const std = @import("std");

const Deployment = @import("../Deployment.zig");
const ClientInstall = @import("../install.zig").Client;
const Project = @import("../Project.zig");
const Term = @import("../Term.zig");
const Client = @import("../Client.zig");

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
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const remote = (try inst.get_remote(&arena, io, step.remote)) orelse return error.InvalidRemote;
    const pipeline = deployment.service.get_pipeline(step.pipeline) orelse return error.InvalidPipeline;
    _ = project;

    var client = try Client.connect(alloc, io, remote);
    defer client.destroy(alloc, io);
    try term.println("Connected to remote", .{});
    try client.conn.send(.{ .request = .task_create });
    try client.conn.send(.{
        .task = .{
            .deployment = .from_deployment(deployment.*),
            .pipeline = step.pipeline,
        },
    });
    try client.conn.send(.{
        .pipeline = pipeline.*,
    });
    {
        var msg_arena: std.heap.ArenaAllocator = .init(alloc);
        defer msg_arena.deinit();
        const msg = try client.conn.recv(&msg_arena);
        try term.println("Recived message: {any}", .{msg});
    }
}
