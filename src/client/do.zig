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
    maybe_continue_id: ?Deployment.Id,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alloc = arena.allocator();

    var deployment: Deployment = undefined;
    if (maybe_continue_id) |id| {
        deployment = try project.load_deployment(alloc, io, id);
        if (project.get_config(alloc, io)) |config| {
            deployment.config = config;
        } else |_| {}
        if (targets.len > 0) {
            const owned_targets = try alloc.dupe(Step, targets);
            deployment.targets = owned_targets;
        }
        term.info("continuing deployment {s}", .{&deployment.id.to_string()});
    } else {
        const owned_targets = try alloc.dupe(Step, targets);
        const config = try project.get_config(alloc, io);
        deployment = try Deployment.create(io, config, owned_targets);
        try deployment.save(alloc, io, project);
        term.info(
            "created deployment {s}",
            .{&deployment.id.to_string()},
        );
    }

    const artifact_dir_path = try project.artifact_dir_path(alloc, io, deployment.id, "src");
    defer alloc.free(artifact_dir_path);
    std.Io.Dir.cwd().access(io, artifact_dir_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try src.create_src_artifact(allocator, io, term, inst, project, deployment.id);
        } else return err;
    };

    try runner.run_deployment(
        alloc,
        io,
        term,
        project,
        inst,
        &deployment,
    );
}
