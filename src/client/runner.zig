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
    initial_deployment: Deployment,
) !Deployment {
    var deployment = initial_deployment;
    while (!deployment.completed()) {
        while (deployment.next()) |next_step|
            deployment = try spawn_next_step(
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
    deployment: Deployment,
    step: Deployment.NextStep,
) !Deployment {
    const remote = (try inst.get_remote(step.remote)) orelse return error.InvalidRemote;
    const client = try Client.connect(alloc, io, remote);
}
