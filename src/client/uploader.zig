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
    const artifact_dir_path = try project.artifact_dir_path(
        alloc,
        io,
        deployment.id,
        artifact.pipeline,
    );
    defer alloc.free(artifact_dir_path);

    if (local_artifact_exists(io, artifact_dir_path))
        return;

    term.info("Fetching artifact '{s}' from remote {s}", .{ artifact.pipeline, remote.get_name() });
    var client = try Client.connect(alloc, io, try remote.get_address(), &try remote.get_token());
    defer client.destroy(alloc, io);

    const conn_buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(conn_buffer);
    try client.conn.send_object(conn_buffer, proto.Request, .artifact_pull);
    try client.conn.send_object(
        conn_buffer,
        proto.artifact.pull.Req,
        .{ .header = .{ .id = artifact } },
    );

    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, artifact_dir_path, .{});
    defer dir.close(io);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var packer: Packer = .unpacker(dir);
    defer packer.deinit(io);
    const pressor_buffer = try alloc.alloc(u8, Pressor.buffer_size);
    defer alloc.free(pressor_buffer);
    var pressor: Pressor = .init(pressor_buffer);
    const decompress_buffer = try alloc.alloc(u8, Pressor.max_uncompressed_size);
    defer alloc.free(decompress_buffer);

    while (true) {
        const res = try client.conn.recv_object(arena.allocator(), proto.artifact.pull.Res);
        switch (res) {
            .file => |path| {
                try packer.put(io, .{ .file = path });
            },
            .folder => |path| {
                try packer.put(io, .{ .folder = path });
            },
            .raw => |data| {
                try packer.put(io, .{ .data = data });
            },
            .compressed => |comp| {
                var input: std.Io.Reader = .fixed(comp);
                var output: std.Io.Writer = .fixed(decompress_buffer);
                try pressor.decompress(&input, &output);
                try packer.put(io, .{ .data = output.buffered() });
            },
            .end => break,
            .footer => break,
        }
        _ = arena.reset(.retain_capacity);
    }
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
) !void {
    const read_buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(read_buffer);
    const send_buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(send_buffer);
    const compressed_buffer = try alloc.alloc(u8, Pressor.max_compressed_size);
    defer alloc.free(compressed_buffer);
    const artifact_dir_path = try project.artifact_dir_path(alloc, io, deployment.id, artifact_id.pipeline);
    defer alloc.free(artifact_dir_path);

    var client = try Client.connect(alloc, io, try remote.get_address(), &try remote.get_token());
    defer client.destroy(alloc, io);

    const conn = &client.conn;

    try conn.send_object(send_buffer, proto.Request, .artifact_push);
    try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .header = .{ .id = artifact_id } });

    const has_artifact = try conn.recv_object_buf(send_buffer, proto.artifact.push.Res);
    switch (has_artifact) {
        .has_artifact => |present| if (present) return,
        .footer => {},
    }

    // The remote does not have it yet: make sure we hold a local copy, pulling
    // it from any other remote that does.
    if (!local_artifact_exists(io, artifact_dir_path)) {
        var fetched = false;
        for (remotes) |*candidate| {
            if (std.mem.eql(u8, candidate.get_name(), remote.get_name()))
                continue;
            get_artifact(alloc, io, term, deployment, artifact_id, candidate, project) catch continue;
            fetched = true;
            break;
        }
        if (!fetched)
            return error.ArtifactNotFound;
    }

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

    while (try packer.get(io, read_buffer)) |pack| switch (pack) {
        .file => |path| {
            try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .file = path });
        },
        .folder => |path| {
            try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .folder = path });
        },
        .data => |data| {
            var reader: std.Io.Reader = .fixed(data);
            var writer: std.Io.Writer = .fixed(compressed_buffer);
            try pressor.compress(&reader, &writer);
            try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .data = writer.buffered() });
        },
    };
    try conn.send_object(send_buffer, proto.artifact.push.Req, .end);

    const reply = try conn.recv_object_buf(send_buffer, anyerror!proto.artifact.push.Res);
    if (reply) |_| {} else |err| {
        return err;
    }
}

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
