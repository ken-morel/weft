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
    do: union(enum) {
        start: []const Step,
        retry: Deployment.Id,
    },
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alloc = arena.allocator();

    var deployment = switch (do) {
        .start => |targets| blk: {
            const owned_targets = try alloc.dupe(Step, targets);
            const config = try project.get_config(alloc, term, io);
            const deployment = try Deployment.create(io, config, owned_targets);
            try deployment.save(alloc, io, project);
            break :blk deployment;
        },
        .retry => |id| blk: {
            var deployment = try project.load_deployment(alloc, io, id);
            deployment.failed = &.{};
            if (project.get_config(alloc, term, io)) |config| {
                deployment.config = config;
            } else |_| {}
            break :blk deployment;
        },
    };

    try src.create_sources(
        alloc,
        io,
        term,
        inst,
        project,
        &deployment,
    );

    try runner.run_deployment(
        alloc,
        io,
        term,
        project,
        inst,
        &deployment,
    );
}
