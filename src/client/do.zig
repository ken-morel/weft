const std = @import("std");
const log = std.log.scoped;

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
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    do: union(enum) {
        start: struct {
            targets: []const Step,
        },
        retry: Deployment.Id,
    },
    env: ?*std.process.Environ.Map,
) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var alloc = arena.allocator();
    const l = log(.cmd_do);

    var deployment = switch (do) {
        .start => |start| blk: {
            const owned_targets = try alloc.dupe(Step, start.targets);
            const config = try project.get_config_leaky(alloc, io);
            const deployment = try Deployment.init(io, config, owned_targets);
            try deployment.save(io, project);
            l.info("starting deployment {s}", .{&deployment.id.to_string()});
            break :blk deployment;
        },
        .retry => |id| blk: {
            l.info("resuming deployment {s}", .{&id.to_string()});
            var deployment = try project.load_deployment_leaky(gpa, alloc, io, id);
            deployment.config = try project.get_config_leaky(alloc, io);
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
        env,
    );
}
