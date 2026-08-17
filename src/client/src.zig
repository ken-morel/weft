const std = @import("std");
const ClientInstall = @import("../ClientInstall.zig");
const Connection = @import("../Connection.zig");
const Client = @import("../Client.zig");
const Deployment = @import("../Deployment.zig");
const Project = @import("../Project.zig");
const Term = @import("../Term.zig");

const runner = @import("runner.zig");

pub fn create_src_artifact(allocator: std.mem.Allocator, io: std.Io, term: *Term, project: Project) !void {
    _ = term;
    _ = allocator;
    _ = project;
    _ = io;
}
