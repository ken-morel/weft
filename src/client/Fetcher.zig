const std = @import("std");

const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const Connection = @import("../wire/Connection.zig");
const Packer = @import("../wire/Packer.zig");
const Pressor = @import("../wire/Pressor.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const DeploymentState = @import("DeploymentState.zig");
const DeploymentView = @import("DeploymentView.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");

dep: *Deployment,
remotes: []const Remote,
pushing: std.StringHashMapUnmanaged(*std.Io.Mutex) = .empty,
pulling: std.StringHashMapUnmanaged(*std.Io.Mutex) = .empty,
map_mutex: std.Io.Mutex = .init,
alloc: std.mem.Allocator,
state: *DeploymentState,
term: *Term,
project: *const Project,
depl: *std.Io.Mutex,
group: std.Io.Group = .init,

pub fn deinit(self: *@This()) void {
    var pushing_iter = self.pushing.iterator();
    while (pushing_iter.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
        self.alloc.destroy(entry.value_ptr.*);
    }
    var pulling_iter = self.pulling.iterator();
    while (pulling_iter.next()) |entry| {
        self.alloc.free(entry.key_ptr.*);
        self.alloc.destroy(entry.value_ptr.*);
    }
    self.pushing.deinit(self.alloc);
    self.pulling.deinit(self.alloc);
}

pub fn has_artifact(self: *@This(), io: std.Io, remote: *const Remote, artifact: []const u8) !bool {
    var client = try Client.connect(self.alloc, io, try remote.get_address(), &try remote.get_token());
    defer client.destroy(self.alloc, io);

    const task_id: proto.task.Id = .{
        .deployment = self.dep.id,
        .pipeline = artifact,
        .workspace = self.dep.config.workspace,
    };

    const buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
    defer self.alloc.free(buffer);

    try client.conn.send_object(buffer, proto.Request, .artifact_has);
    try client.conn.send_object(buffer, proto.artifact.has.Req, .{ .id = task_id });

    const reply = try try client.conn.recv_object(self.alloc, proto.Res(proto.artifact.has.Res));
    return reply.has;
}

fn get_mutex(self: *@This(), io: std.Io, map: *std.StringHashMapUnmanaged(*std.Io.Mutex), key_str: []const u8) !*std.Io.Mutex {
    self.map_mutex.lockUncancelable(io);
    defer self.map_mutex.unlock(io);

    if (map.get(key_str)) |m| {
        return m;
    }

    const key = try self.alloc.dupe(u8, key_str);
    errdefer self.alloc.free(key);
    const m = try self.alloc.create(std.Io.Mutex);
    m.* = .init;
    try map.put(self.alloc, key, m);
    return m;
}

pub fn fetch(self: *@This(), io: std.Io, artifact: []const u8) !void {
    if (Weft.is_source_artifact(artifact)) {
        const artifact_path = try self.project.artifact_dir_path(self.alloc, io, self.dep.id, artifact);
        defer self.alloc.free(artifact_path);
        return std.Io.Dir.cwd().access(io, artifact_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                self.term.err("Source artifact {s} couldn't be found", .{artifact});
                return error.InvalidSourceArtifact;
            } else return err;
        };
    }

    const m = try self.get_mutex(io, &self.pulling, artifact);
    try m.lock(io);
    defer m.unlock(io);

    const artifact_path = try self.project.artifact_dir_path(self.alloc, io, self.dep.id, artifact);
    defer self.alloc.free(artifact_path);

    std.Io.Dir.cwd().access(io, artifact_path, .{}) catch |err| {
        if (err == error.FileNotFound)
            try self.pull_artifact(io, artifact)
        else
            return err;
    };
}

pub fn upload(self: *@This(), io: std.Io, remote: *const Remote, artifact: []const u8) !void {
    if (try self.has_artifact(io, remote, artifact)) {
        self.state.artifact_progress(io, artifact, remote, .ready, 1.0) catch {};
        return;
    }

    try self.fetch(io, artifact);

    const push_id = try std.mem.join(self.alloc, ".", &.{ remote.get_name(), artifact });
    defer self.alloc.free(push_id);

    const m = try self.get_mutex(io, &self.pushing, push_id);
    try m.lock(io);
    defer m.unlock(io);

    if (try self.has_artifact(io, remote, artifact))
        return;
    try self.push_artifact(io, remote, artifact);
}

pub fn push_artifact(self: *@This(), io: std.Io, remote: *const Remote, artifact: []const u8) !void {
    try self.state.artifact_progress(io, artifact, remote, .pushing, 0.0);
    defer self.state.artifact_progress(io, artifact, remote, .ready, 1.0) catch {};

    const read_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
    defer self.alloc.free(read_buffer);
    const send_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
    defer self.alloc.free(send_buffer);
    const compressed_buffer = try self.alloc.alloc(u8, Pressor.chunk_size);
    defer self.alloc.free(compressed_buffer);
    const artifact_dir_path = try self.project.artifact_dir_path(self.alloc, io, self.dep.id, artifact);
    defer self.alloc.free(artifact_dir_path);

    var client = try Client.connect(self.alloc, io, try remote.get_address(), &try remote.get_token());
    defer client.destroy(self.alloc, io);

    const conn = &client.conn;
    const task_id: proto.task.Id = .{
        .deployment = self.dep.id,
        .pipeline = artifact,
        .workspace = self.dep.config.workspace,
    };

    try conn.send_object(send_buffer, proto.Request, .artifact_push);
    try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .header = .{ .id = task_id } });

    const check_res = try conn.recv_object_buf(send_buffer, proto.artifact.push.Res);
    switch (check_res) {
        .has_artifact => |present| if (present) return,
        .footer => {},
    }

    var total_files: u32 = 0;
    {
        var count_dir = try std.Io.Dir.cwd().openDir(io, artifact_dir_path, .{ .iterate = true });
        defer count_dir.close(io);
        var count_walker = try count_dir.walk(self.alloc);
        defer count_walker.deinit();
        while (try count_walker.next(io)) |entry|
            if (entry.kind == .file) {
                total_files += 1;
            };
    }

    var artifact_dir = try std.Io.Dir.cwd().openDir(
        io,
        artifact_dir_path,
        .{
            .iterate = true,
        },
    );
    defer artifact_dir.close(io);

    var packer: Packer = try .packer(
        self.alloc,
        artifact_dir,
    );
    defer packer.deinit(io);
    const pressor_buffer = try self.alloc.alloc(u8, Pressor.buffer_size);
    defer self.alloc.free(pressor_buffer);
    var pressor: Pressor = .init(pressor_buffer);

    var sent_files: u32 = 0;
    while (try packer.get(io, read_buffer)) |pack| switch (pack) {
        .file => |path| {
            try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .file = path });
            sent_files += 1;
            const pct = if (total_files > 0)
                @as(f32, @floatFromInt(sent_files)) / @as(f32, @floatFromInt(total_files))
            else
                1.0;
            try self.state.artifact_progress(io, artifact, remote, .pushing, pct);
        },
        .folder => |path| try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .folder = path }),
        .data => |data| {
            var reader: std.Io.Reader = .fixed(data);
            var writer: std.Io.Writer = .fixed(compressed_buffer);
            if (pressor.compress(&reader, &writer)) |_| {
                if (writer.buffered().len < data.len)
                    try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .data = writer.buffered() })
                else
                    try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .raw = data });
            } else |err| {
                if (err != error.WriteFailed)
                    return err;
                try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .raw = data });
            }
        },
    };
    try conn.send_object(send_buffer, proto.artifact.push.Req, .end);

    const reply = try conn.recv_object_buf(send_buffer, anyerror!proto.artifact.push.Res);
    if (reply) |_| {} else |err| return err;
}

pub fn pull_artifact(self: *@This(), io: std.Io, artifact: []const u8) !void {
    const remote: *const Remote = remote: {
        try self.depl.lock(io);
        defer self.depl.unlock(io);
        for (self.dep.artifacts) |*art| {
            if (std.mem.eql(u8, art.name, artifact))
                for (self.remotes) |*rem|
                    if (std.mem.eql(u8, rem.get_name(), art.remote))
                        break :remote rem;
        } else return error.ArtifactNotFound;
    };

    try self.state.artifact_progress(io, artifact, remote, .pulling, 0.0);
    defer self.state.artifact_progress(io, artifact, remote, .ready, 1.0) catch {};

    var client = try Client.connect(self.alloc, io, try remote.get_address(), &try remote.get_token());
    defer client.destroy(self.alloc, io);

    const artifact_path = try self.project.artifact_dir_path(self.alloc, io, self.dep.id, artifact);
    defer self.alloc.free(artifact_path);

    const conn_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
    defer self.alloc.free(conn_buffer);

    const task_id: proto.task.Id = .{
        .deployment = self.dep.id,
        .pipeline = artifact,
        .workspace = self.dep.config.workspace,
    };

    try client.conn.send_object(conn_buffer, proto.Request, .artifact_pull);
    try client.conn.send_object(
        conn_buffer,
        proto.artifact.pull.Req,
        .{ .header = .{ .id = task_id } },
    );

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, artifact_path, .{});
    defer dir.close(io);

    var packer: Packer = .unpacker(dir);
    defer packer.deinit(io);
    const pressor_buffer = try self.alloc.alloc(u8, Pressor.buffer_size);
    defer self.alloc.free(pressor_buffer);
    var pressor: Pressor = .init(pressor_buffer);
    const decompress_buffer = try self.alloc.alloc(u8, Pressor.chunk_size);
    defer self.alloc.free(decompress_buffer);

    var total_files: u32 = 0;
    var received_files: u32 = 0;

    const initial = try client.conn.recv_object_buf(conn_buffer, proto.artifact.pull.Res);
    switch (initial) {
        .files => |f| total_files = f,
        .footer => {},
    }

    while (true) {
        const data = try client.conn.recv_buf(conn_buffer);
        if (data.len < 5 or !std.mem.eql(u8, data[0..4], "pack"))
            return error.ExpectedPackHeader;

        switch (data[4]) {
            proto.file => {
                const path = data[5..];
                try packer.put(io, .{ .file = path });
                received_files += 1;
                const pct = if (total_files > 0)
                    @as(f32, @floatFromInt(received_files)) / @as(f32, @floatFromInt(total_files))
                else
                    1.0;
                try self.state.artifact_progress(io, artifact, remote, .pulling, pct);
            },
            proto.folder => {
                const path = data[5..];
                try packer.put(io, .{ .folder = path });
            },
            proto.data => {
                const bytes = data[5..];
                try packer.put(io, .{ .data = bytes });
            },
            proto.compressed_data => {
                const comp = data[5..];
                var input: std.Io.Reader = .fixed(comp);
                var output: std.Io.Writer = .fixed(decompress_buffer);
                try pressor.decompress(&input, &output);
                try packer.put(io, .{ .data = output.buffered() });
            },
            proto.end => break,
            else => return error.InvalidPack,
        }
    }

    _ = try try client.conn.recv_object_buf(conn_buffer, proto.Res(proto.artifact.pull.Res));
}

pub fn spawn_fetch(self: *@This(), io: std.Io, artifact: []const u8) !void {
    const key = try self.alloc.dupe(u8, artifact);
    errdefer self.alloc.free(key);

    try spawn(io, &self.group, fetch_wrapper, .{ self, io, key });
}

fn fetch_wrapper(self: *@This(), io: std.Io, key: []const u8) !void {
    defer self.alloc.free(key);
    self.fetch(io, key) catch |e| {
        self.term.err("failed to fetch artifact {s}: {any}", .{ key, e });
    };
}

pub fn is_idle(self: *@This(), io: std.Io) bool {
    self.state.mutex.lockUncancelable(io);
    defer self.state.mutex.unlock(io);

    for (self.state.artifacts.items) |art|
        if (art.status == .pulling or art.status == .pushing)
            return false;

    return true;
}
