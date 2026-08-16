const std = @import("std");

const Deployment = @import("../Deployment.zig");
const ClientInstall = @import("../ClientInstall.zig");
const Project = @import("../Project.zig");
const Term = @import("../Term.zig");
const Client = @import("../Client.zig");
const ids = @import("../ids.zig");
const UUIDv7 = @import("../UUIDv7.zig");

pub fn upload_artifacts(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    deployment: UUIDv7,
    artifacts: [][]const u8,
) !void {
    _ = alloc;
    _ = io;
    _ = term;
    _ = project;
    _ = inst;
    _ = deployment;
    _ = artifacts;
}
