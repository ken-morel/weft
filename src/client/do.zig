const std = @import("std");
const ClientInstall = @import("../ClientInstall.zig");
const Connection = @import("../Connection.zig");
const Client = @import("../Client.zig");
const Deployment = @import("../Deployment.zig");
const Step = @import("../Step.zig");
const Project = @import("../Project.zig");
const Term = @import("../Term.zig");

const src = @import("src.zig");
const runner = @import("runner.zig");

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
    try term.info(
        "created deployment {s}",
        .{&deployment.uuid.to_string()},
    );
    try src.create_src_artifact(allocator, io, term, inst, project, deployment.uuid);
    try runner.run_deployment(
        alloc,
        io,
        term,
        project,
        inst,
        &deployment,
    );
}
