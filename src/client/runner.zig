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
    try term.printlnf("spawning deployment step: {s} on {s}", .{ step.pipeline, step.remote });
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const remote = (try inst.get_remote(&arena, io, step.remote)) orelse {
        try term.err("Invalid remote: {s}", .{step.remote});
        return error.InvalidRemote;
    };
    const pipeline = deployment.service.get_pipeline(step.pipeline) orelse return error.InvalidPipeline;

    try uploader.send_required_artifacts(alloc, io, term, inst, project, deployment.*, pipeline.*, remote);
}
