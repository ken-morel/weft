const std = @import("std");
const ClientInstall = @import("../install/client.zig");
const Connection = @import("../net/Connection.zig");
const Client = @import("../net/Client.zig");
const Deployment = @import("../model/Deployment.zig");
const Target = @import("../model/Target.zig");
const Project = @import("../project/Project.zig");
const Term = @import("../util/Term.zig");

const runner = @import("runner.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    targets: []const Target,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alloc = arena.allocator();
    const owned_targets = try alloc.dupe(Target, targets);

    const config = try project.get_config(&arena, io);
    var deployment = try Deployment.create(alloc, io, config, owned_targets);
    try deployment.save(io, project);
    var buff: [36]u8 = undefined;
    try term.println(
        "Created deploymeent {s}",
        .{try deployment.uuid.to_string(&buff)},
    );
    try term.flush();
    try runner.run_deployment(
        alloc,
        io,
        term,
        project,
        inst,
        &deployment,
    );
}
