const std = @import("std");

const Deployment = @import("../Deployment.zig");
const ClientInstall = @import("../ClientInstall.zig");
const Project = @import("../Project.zig");
const Term = @import("../Term.zig");
const Client = @import("../Client.zig");
const ids = @import("../ids.zig");
const UUIDv7 = @import("../UUIDv7.zig");
const Pipeline = @import("../Weft.zig").Pipeline;
const Remote = @import("../Remote.zig");
const Connection = @import("../Connection.zig");
const zoto = @import("../zoto.zig");
const Packer = @import("../packer.zig").Packer;

pub fn cache_artifact(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    inst: *const ClientInstall,
    artifact_id: ids.ArtifactId,
    project: *const Project,
    deployment: *const Deployment,
) !void {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const artifact_dir_path = try project.artifact_dir_path(alloc, io, deployment.uuid, artifact_id.pipeline);
    defer alloc.free(artifact_dir_path);

    blk: {
        std.Io.Dir.cwd().access(io, artifact_dir_path, .{}) catch break :blk;
        return;
    }
    const source_artifact = artifact: {
        for (deployment.artifacts) |*artifact|
            if (std.mem.eql(u8, artifact.step.pipeline, artifact_id.pipeline))
                break :artifact artifact;
        unreachable;
    };
    const remote = (try inst.get_remote(&arena, io, source_artifact.step.remote)) orelse return error.InvalidRemote;
    // get the artifact from the remote...
    try term.printlnf("Requested the artifact from remote {s}", .{remote.name});
}
pub fn send_artifact(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    inst: *const ClientInstall,
    artifact_id: ids.ArtifactId,
    project: *const Project,
    deployment: *const Deployment,
    remote: *const Remote,
) !void {
    var msg_arena: std.heap.ArenaAllocator = .init(alloc);
    defer msg_arena.deinit();
    const artifact_dir_path = try project.artifact_dir_path(alloc, io, deployment.uuid, artifact_id.pipeline);
    defer alloc.free(artifact_dir_path);

    var client = try Client.connect(alloc, io, remote.*);
    defer client.destroy(alloc, io);

    const conn = &client.conn;

    try conn.send(.{ .request = .artifact_push });
    try conn.send(.{ .artifact_id = artifact_id });
    {
        const reply = try conn.recv(&msg_arena);
        defer _ = msg_arena.reset(.retain_capacity);
        switch (reply) {
            .bool => |has_artifact| if (has_artifact) return,
            else => return error.SyntaxError,
        }
    }
    try cache_artifact(
        alloc,
        io,
        term,
        inst,
        artifact_id,
        project,
        deployment,
    );

    var packer: *Packer = try .create(
        alloc,
        try std.Io.Dir.cwd().openDir(
            io,
            artifact_dir_path,
            .{
                .iterate = true,
            },
        ),
    );
    defer packer.destroy(alloc, io);

    try client.upload_pack(io, packer);

    {
        defer _ = msg_arena.reset(.retain_capacity);
        const msg = try conn.recv(&msg_arena);
        switch (msg) {
            .ok => try term.printlnf("Upload okay", .{}),
            else => try term.err("Upload error: {any}", .{msg}),
        }
    }
}

pub fn send_artifact_concurrent(
    alloc: std.mem.Allocator,
    io: std.Io,
    group: *std.Io.Group,
    term: *Term,
    inst: *const ClientInstall,
    artifact_id: ids.ArtifactId,
    project: *const Project,
    deployment: *const Deployment,
    remote: *const Remote,
) error{Canceled}!void {
    send_artifact(
        alloc,
        io,
        term,
        inst,
        artifact_id,
        project,
        deployment,
        remote,
    ) catch |err|
        if (err == error.Canceled)
            return error.Canceled
        else {
            term.err("Error sending artifact: {any}", .{err}) catch {};
            group.cancel(io);
        };
}
pub fn send_required_artifacts(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    inst: ClientInstall,
    project: Project,
    deployment: Deployment,
    pipeline: Pipeline,
    remote: Remote,
) !void {
    var group: std.Io.Group = .init;

    for (pipeline.inputs) |input| {
        try group.concurrent(
            io,
            send_artifact_concurrent,
            .{
                alloc,    io,          &group,  term, &inst,
                ids.ArtifactId{
                    .deployment = deployment.uuid,
                    .pipeline = input.name,
                    .service = .{
                        .name = deployment.service.name,
                        .workspace = deployment.service.workspace,
                    },
                },
                &project, &deployment, &remote,
            },
        );
    }
    try group.await(io);
}
