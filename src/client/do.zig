const std = @import("std");

const Term = @import("../domain/Term.zig");
const Connection = @import("../wire/Connection.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const runner = @import("runner.zig");
const src = @import("src.zig");
const Step = @import("Step.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    targets: []const Step,
) !void {
    const env = "main";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alloc = arena.allocator();
    const owned_targets = try alloc.dupe(Step, targets);

    const config = try project.get_config(arena.allocator(), io);
    var deployment = try Deployment.create(io, config, env, owned_targets);
    try deployment.save(alloc, io, project);
    term.info(
        "created deployment {s}",
        .{&deployment.id.to_string()},
    );
    try src.create_src_artifact(allocator, io, term, inst, project, deployment.id);
    try runner.run_deployment(
        alloc,
        io,
        term,
        project,
        inst,
        &deployment,
    );
}
