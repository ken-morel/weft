const std = @import("std");

const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const Term = @import("../domain/Term.zig");
const Connection = @import("../wire/Connection.zig");
const Packer = @import("../wire/Packer.zig");
const Pressor = @import("../wire/Pressor.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const DeploymentState = @import("DeploymentState.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");
const State = @import("DeploymentState.zig");
const uploader = @import("uploader.zig");

const Fetcher = struct {
    deployment: *Deployment,
    remotes: []const Remote,
    pushing: std.StringHashMapUnmanaged(std.Io.Mutex),
    pulling: std.StringHashMapUnmanaged(std.Io.Mutex),
    alloc: std.mem.Allocator,
    state: *State,
    term: *Term,
    project: *Project,

    pub fn add(self: *@This(), io: std.Io, remote: *const Remote, artifact: []const u8) !void {
        _ = fetch_artifact: {
            const m = m: {
                if (self.pulling.getPtr(artifact)) |m| {
                    m.lock(io);
                    break :m m;
                } else {
                    try self.pulling.put(self.alloc, artifact, .init);
                    const m = self.pulling.getPtr(artifact).?;
                    m.lockUncancelable(io);
                    break :m m;
                }
            };
            defer m.unlock(io);

            const artifact_path = try self.project.artifact_dir_path(self.alloc, self.io, self.deployment.id, artifact);

            defer self.alloc.free(artifact_path);

            std.Io.Dir.cwd().access(io, artifact_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    try self.pull_artifact(io, artifact);
                } else return err;
            };
            break :fetch_artifact;
        };
        const push_id = try std.mem.join(self.alloc, ".", &.{ remote.name, artifact });
        const m = m: {
            if (self.pushing.getPtr(push_id)) |m| {
                m.lock(io);
                break :m m;
            } else {
                try self.pushing.put(self.alloc, push_id, .init);
                const m = self.pulling.getPtr(push_id).?;
                m.lockUncancelable(io);
                break :m m;
            }
        };
        defer m.unlock();
        try self.push_artifact(io, remote, artifact);
    }
    pub fn push_artifact(self: *@This(), io: std.Io, remote: *const Remote, artifact: []const u8) !void {
        const read_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
        defer self.alloc.free(read_buffer);
        const send_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
        defer self.alloc.free(send_buffer);
        const compressed_buffer = try self.alloc.alloc(u8, Pressor.max_compressed_size);
        defer self.alloc.free(compressed_buffer);
        const artifact_dir_path = try self.project.artifact_dir_path(self.alloc, io, self.deployment.id, artifact);
        defer self.alloc.free(artifact_dir_path);

        var client = try Client.connect(self.alloc, io, try remote.get_address(), &try remote.get_token());
        defer client.destroy(self.alloc, io);

        const conn = &client.conn;

        try conn.send_object(send_buffer, proto.Request, .artifact_push);
        try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .header = .{ .id = artifact } });

        const has_artifact = try conn.recv_object_buf(send_buffer, proto.artifact.push.Res);
        switch (has_artifact) {
            .has_artifact => |present| if (present) return,
            .footer => {},
        }

        var packer: Packer = try .packer(
            self.alloc,
            try std.Io.Dir.cwd().openDir(
                io,
                artifact_dir_path,
                .{
                    .iterate = true,
                },
            ),
        );
        defer packer.deinit(io);
        const pressor_buffer = try self.alloc.alloc(u8, Pressor.buffer_size);
        defer self.alloc.free(pressor_buffer);
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
        if (reply) |_| {} else |err| return err;
    }
    pub fn pull_artifact(self: *@This(), io: std.Io, artifact: []const u8) !void {
        const remote: *const Remote = remote: for (self.deployment.artifacts) |*art| {
            if (std.mem.eql(u8, art.name, artifact))
                for (self.remotes) |*rem|
                    if (std.mem.eql(u8, rem.get_name(), art.remote))
                        break :remote rem;
        } else return error.ArtifactNotFound;

        var client: Client = .connect(self.alloc, io, try remote.get_address(), try remote.get_token());
        defer client.destroy(self.allo, io);
        const artifact_path = try self.project.artifact_dir_path(self.alloc, self.io, self.deployment.id, artifact);
        defer self.alloc.free(artifact_path);
        const artifact_dir = std.Io.Dir.cwd().open(artifact_path);
        defer artifact_dir.close(io);

        const conn_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
        defer self.alloc.free(conn_buffer);
        try client.conn.send_object(conn_buffer, proto.Request, .artifact_pull);
        try client.conn.send_object(
            conn_buffer,
            proto.artifact.pull.Req,
            .{ .header = .{ .id = artifact } },
        );

        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, artifact_path, .{});
        defer dir.close(io);

        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        var packer: Packer = .unpacker(dir);
        defer packer.deinit(io);
        const pressor_buffer = try self.alloc.alloc(u8, Pressor.buffer_size);
        defer self.alloc.free(pressor_buffer);
        var pressor: Pressor = .init(pressor_buffer);
        const decompress_buffer = try self.alloc.alloc(u8, Pressor.max_uncompressed_size);
        defer self.alloc.free(decompress_buffer);

        while (true) : (_ = arena.reset(.retain_capacity)) {
            const res = try client.conn.recv_object(arena.allocator(), proto.artifact.pull.Res);
            switch (res) {
                .file => |path| try packer.put(io, .{ .file = path }),
                .folder => |path| try packer.put(io, .{ .folder = path }),
                .raw => |data| try packer.put(io, .{ .data = data }),
                .compressed => |comp| {
                    var input: std.Io.Reader = .fixed(comp);
                    var output: std.Io.Writer = .fixed(decompress_buffer);
                    try pressor.decompress(&input, &output);
                    try packer.put(io, .{ .data = output.buffered() });
                },
                .end => break,
                .footer => break,
            }
        }
    }
};

pub fn run_deployment(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    deployment: *Deployment,
) !void {
    const remotes = try inst.get_remotes(alloc, io, term);

    var state: DeploymentState = .init(deployment);

    var fetcher: Fetcher = .{
        .alloc = alloc,
        .deployment = deployment,
        .project = project,
        .pulling = .empty,
        .pushing = .empty,
        .remotes = remotes,
        .term = term,
        .state = &state,
    };
    var signal: std.Io.Condition = .init;
    var group: std.Io.Group = .init;
    while (!deployment.completed()) {
        while (try deployment.next_step()) |step|
            spawn(
                io,
                &group,
                spawn_step,
                .{ alloc, io, &state, &signal, project, deployment, remotes, &fetcher, step },
            );
    }
}
pub fn spawn_step(
    alloc: std.mem.Allocator,
    io: std.Io,
    state: *State,
    signal: *std.Io.Condition,
    project: Project,
    deployment: *Deployment,
    remotes: []const Remote,
    fetcher: *Fetcher,
    step: Deployment.Step,
) !void {
    var buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(buffer);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const remote: *const Remote = remote: for (remotes) |*remote| {
        if (std.mem.eql(u8, remote.get_name(), step.remote))
            break :remote remote;
    } else return error.InvalidRemote;
    const pipeline = deployment.service.get_pipeline(step.pipeline) orelse {
        return error.InvalidPipeline;
    };

    for (pipeline.inputs) |input| {
        try fetcher.add(io, remote, input.name);
    }

    const client = try Client.connect(alloc, io, try remote.get_address(), &try remote.get_token());
    defer client.destroy(alloc, io);

    try client.conn.send_object(buffer, proto.Request, .task_spawn);
    try client.conn.send_object(buffer, proto.task.spawn.Req, .{
        .task = .{
            .deployment = deployment.id,
            .env = deployment.env,
            .pipeline = pipeline.name,
            .service = deployment.service.name,
            .workspace = deployment.service.workspace,
        },
        .pipeline = pipeline.*,
    });

    const script_path = try std.fs.path.join(alloc, &.{
        "bin",
        pipeline.script orelse pipeline.name,
    });
    defer alloc.free(script_path);

    const script = project.dir.openFile(io, script_path, .{}) catch |err| {
        if (err == error.FileNotFound)
            term.err("Script {s} does not exist, cannot run pipeline {s}", .{ script_path, pipeline.name });
        return err;
    };
    defer script.close(io);

    while (true) {
        const size = script.readStreaming(io, &.{buffer[1..]}) catch |err|
            if (err == error.EndOfStream)
                break
            else
                return err;
        buffer[0] = proto.task.spawn.data;
        try client.conn.send(buffer[0 .. size + 1]);
    }
    buffer[0] = proto.task.spawn.end;
    try client.conn.send(buffer[0..1]);
    const reply = try client.conn.recv_object_buf(buffer, proto.Res(proto.task.spawn.Res));
    if (reply) |_| {
        deployment.running = try alloc.realloc(deployment.running, deployment.running.len + 1);
        const item = &deployment.running[deployment.running.len - 1];
        item.* = step;
        term.success("Spawned task succesfully", .{});
    } else |err| {
        term.err("Remote error: {any}", .{err});
        return err;
    }

    term.info("Waiting for a second...", .{});
    try std.Io.sleep(io, .fromSeconds(1), .real);
}
