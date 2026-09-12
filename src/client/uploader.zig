const std = @import("std");

const Client = @import("../Client.zig");
const ClientInstall = @import("../ClientInstall.zig");
const Connection = @import("../Connection.zig");
const Deployment = @import("../Deployment.zig");
const Packer = @import("../Packer.zig");
const Pressor = @import("../Pressor.zig");
const Project = @import("../Project.zig");
const proto = @import("../proto.zig");
const Remote = @import("../Remote.zig");
const Term = @import("../Term.zig");
const UUIDv7 = @import("../UUIDv7.zig");
const Pipeline = @import("../Weft.zig").Pipeline;
const zoto = @import("../zoto.zig");

pub fn cache_artifact(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    inst: *const ClientInstall,
    artifact_id: proto.task.Id,
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
            if (std.mem.eql(u8, artifact.name, artifact_id.pipeline))
                break :artifact artifact;
        unreachable;
    };
    const remote = (try inst.get_remote(arena.allocator(), io, source_artifact.remote)) orelse return error.InvalidRemote;
    // get the artifact from the remote...
    try term.info("requesting artifact '{s}' from remote {s}", .{ artifact_id.pipeline, remote.name });
}

pub fn send_artifact(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    inst: *const ClientInstall,
    artifact_id: proto.task.Id,
    project: *const Project,
    deployment: *const Deployment,
    remote: *const Remote,
) !void {
    const buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(buffer);
    const artifact_dir_path = try project.artifact_dir_path(alloc, io, deployment.uuid, artifact_id.pipeline);
    defer alloc.free(artifact_dir_path);

    var client = try Client.connect(alloc, io, remote.address, &remote.token);
    defer client.destroy(alloc, io);

    const conn = &client.conn;

    try conn.send_object(buffer, proto.Request.artifact_push);
    try conn.send_object(buffer, proto.artifact.push.Req{ .id = artifact_id });

    const has_artifact = try conn.recv_object_buf(buffer, bool);
    if (has_artifact)
        return;

    try cache_artifact(
        alloc,
        io,
        term,
        inst,
        artifact_id,
        project,
        deployment,
    );

    var packer: Packer = try .packer(
        alloc,
        try std.Io.Dir.cwd().openDir(
            io,
            artifact_dir_path,
            .{
                .iterate = true,
            },
        ),
    );
    defer packer.deinit(io);
    const pressor_buffer = try alloc.alloc(u8, Pressor.buffer_size);
    defer alloc.free(pressor_buffer);
    var pressor: Pressor = .init(pressor_buffer);

    const output = try alloc.alloc(u8, buffer.len);
    defer alloc.free(output);
    while (try packer.get(io, buffer)) |pack| switch (pack) {
        .file => |path| {
            buffer[0] = proto.artifact.push.file;
            std.mem.copyForwards(u8, buffer[1..], path);
            try client.conn.send(buffer[0 .. 1 + path.len]);
        },
        .folder => |path| {
            buffer[0] = proto.artifact.push.folder;
            std.mem.copyForwards(u8, buffer[1..], path);
            try client.conn.send(buffer[0 .. 1 + path.len]);
        },
        .data => |data| {
            var reader: std.Io.Reader = .fixed(data);
            var writer: std.Io.Writer = .fixed(output);
            try writer.writeByte(proto.artifact.push.compressed);
            try pressor.compress(&reader, &writer);
            try client.conn.send(writer.buffered());
        },
    };
    buffer[0] = proto.artifact.push.end;
    try client.conn.send(buffer[0..1]);

    const reply = try client.conn.recv_object_buf(buffer, anyerror!proto.artifact.push.Res);
    if (reply) |_| {} else |err| {
        return err;
    }
}

pub fn send_artifact_concurrent(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    inst: *const ClientInstall,
    artifact_id: proto.task.Id,
    project: *const Project,
    deployment: *const Deployment,
    remote: *const Remote,
    failed: *?u16,
) error{Canceled}!void {
    term.info("sending artifact {s} to remote {s}", .{ artifact_id.pipeline, remote.name }) catch {};
    send_artifact(
        alloc,
        io,
        term,
        inst,
        artifact_id,
        project,
        deployment,
        remote,
    ) catch |err| {
        if (err == error.HasArtifact) {
            term.err("Remote has artifact, skipping", .{}) catch {};
        } else {
            term.err("error sending artifact '{s}': {any}", .{ artifact_id.pipeline, err }) catch {};
            failed.* = @intFromError(err);
        }
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

    var failed: ?u16 = null;
    for (pipeline.inputs) |input| {
        try group.concurrent(
            io,
            send_artifact_concurrent,
            .{ alloc, io, term, &inst, proto.task.Id{
                .deployment = deployment.uuid,
                .pipeline = input.name,
                .env = deployment.env,
                .service = deployment.service.name,
                .workspace = deployment.service.workspace,
            }, &project, &deployment, &remote, &failed },
        );
    }
    try group.await(io);
    if (failed) |err|
        return @errorFromInt(err);
}
