const std = @import("std");

const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const Pipeline = @import("../domain/Weft.zig").Pipeline;
const zoto = @import("../util/zoto.zig");
const Connection = @import("../wire/Connection.zig");
const Packer = @import("../wire/Packer.zig");
const Pressor = @import("../wire/Pressor.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");

pub fn get_artifact(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    deployment: *const Deployment,
    artifact: proto.artifact.Id,
    remote: *const Remote,
    project: *const Project,
) !void {
    if (local_artifact_exists(io, artifact_dir_path))
        return;

    term.info("Fetching artifact '{s}' from remote {s}", .{ artifact.pipeline, remote.get_name() });
    var client = try Client.connect(alloc, io, try remote.get_address(), &try remote.get_token());
    defer client.destroy(alloc, io);

    term.success("Downloaded artifact '{s}'", .{artifact.pipeline});
}

fn local_artifact_exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn send_artifact(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    artifact_id: proto.task.Id,
    project: *const Project,
    deployment: *const Deployment,
    remotes: []const Remote,
    remote: *const Remote,
) !void {}

pub fn send_artifact_concurrent(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    artifact_id: proto.task.Id,
    project: *const Project,
    deployment: *const Deployment,
    remotes: []const Remote,
    remote: *const Remote,
    failed: *?u16,
) error{Canceled}!void {
    term.info("sending artifact {s} to remote {s}", .{ artifact_id.pipeline, remote.get_name() });
    send_artifact(
        alloc,
        io,
        term,
        artifact_id,
        project,
        deployment,
        remotes,
        remote,
    ) catch |err| {
        if (err == error.HasArtifact) {
            term.err("Remote has artifact, skipping", .{});
        } else {
            term.err("error sending artifact '{s}': {any}", .{ artifact_id.pipeline, err });
            failed.* = @intFromError(err);
        }
    };
}
pub fn send_required_artifacts(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    deployment: Deployment,
    pipeline: Pipeline,
    remotes: []const Remote,
    remote: *const Remote,
) !void {
    var group: std.Io.Group = .init;

    var failed: ?u16 = null;
    for (pipeline.inputs) |input| {
        try group.concurrent(
            io,
            send_artifact_concurrent,
            .{ alloc, io, term, proto.task.Id{
                .deployment = deployment.id,
                .pipeline = input.name,
                .env = deployment.env,
                .service = deployment.service.name,
                .workspace = deployment.service.workspace,
            }, &project, &deployment, remotes, remote, &failed },
        );
    }
    try group.await(io);
    if (failed) |err|
        return @errorFromInt(err);
}
