const std = @import("std");
const install = @import("../install.zig");
const Connection = @import("../Connection.zig");
const Client = @import("../Client.zig");
const Deployment = @import("../Deployment.zig");
const Project = @import("../Project.zig");
const Term = @import("../Term.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: *const Project,
    inst: *const install.Client,
    targets: []const Deployment.Target,
) !void {
    _ = inst;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alloc = arena.allocator();
    const owned_targets = try alloc.dupe(Deployment.Target, targets);

    const config = try project.get_config(&arena, io);
    var deployment = try Deployment.create(alloc, io, config, owned_targets);
    try deployment.save(io, project);
    var buff: [36]u8 = undefined;
    try term.println(
        "Created deploymeent {s}",
        .{try deployment.uuid.to_string(&buff)},
    );
    try term.flush();
}
