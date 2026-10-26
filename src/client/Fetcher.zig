const std = @import("std");
const log = std.log.scoped;

const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const Remote = Weft.Remote;
const Connection = @import("../wire/Connection.zig");
const Identity = @import("../wire/Identity.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const DeploymentState = @import("DeploymentState.zig");
const DeploymentView = @import("DeploymentView.zig");
const Project = @import("Project.zig");
const transfer = @import("transfer.zig");

dep: *Deployment,
identity: Identity,
remotes: []const Remote,
pushing: std.StringHashMapUnmanaged(*std.Io.Mutex) = .empty,
pulling: std.StringHashMapUnmanaged(*std.Io.Mutex) = .empty,
map_mutex: std.Io.Mutex = .init,
gpa: std.mem.Allocator,
state: *DeploymentState,
term: *Term,
project: *const Project,
depl: *std.Io.Mutex,
group: std.Io.Group = .init,

pub fn deinit(self: *@This(), io: std.Io) void {
    self.group.cancel(io);
    self.group.await(io) catch |err| {
        std.log.scoped(.fetcher_deinit).warn("Fetcher tasks failed to await cleanly during deinit: {any}", .{err});
    };
    var pushing_iter = self.pushing.iterator();
    while (pushing_iter.next()) |entry| {
        self.gpa.free(entry.key_ptr.*);
        self.gpa.destroy(entry.value_ptr.*);
    }
    var pulling_iter = self.pulling.iterator();
    while (pulling_iter.next()) |entry| {
        self.gpa.free(entry.key_ptr.*);
        self.gpa.destroy(entry.value_ptr.*);
    }
    self.pushing.deinit(self.gpa);
    self.pulling.deinit(self.gpa);
}

pub fn has_artifact(self: *@This(), io: std.Io, remote: *const Remote, artifact: []const u8) !bool {
    var client = try Client.connect(self.gpa, io, try Weft.parse_remote_address(io, remote.*), self.identity);
    defer client.destroy(self.gpa, io);

    const task_id: proto.task.Id = .{
        .deployment = self.dep.id,
        .pipeline = artifact,
        .workspace = self.dep.config.workspace,
    };

    const buffer = try self.gpa.alloc(u8, Connection.max_packet_size);
    defer self.gpa.free(buffer);

    try client.conn.send_object(buffer, proto.Request, .artifact_has);
    try client.conn.send_object(buffer, proto.artifact.has.Req, .{ .id = task_id });

    const reply = try try client.conn.recv_object(self.gpa, proto.Res(proto.artifact.has.Res));
    return reply.has;
}

fn get_mutex(self: *@This(), io: std.Io, map: *std.StringHashMapUnmanaged(*std.Io.Mutex), key_str: []const u8) !*std.Io.Mutex {
    self.map_mutex.lockUncancelable(io);
    defer self.map_mutex.unlock(io);

    if (map.get(key_str)) |m| {
        return m;
    }

    const key = try self.gpa.dupe(u8, key_str);
    errdefer self.gpa.free(key);
    const m = try self.gpa.create(std.Io.Mutex);
    m.* = .init;
    try map.put(self.gpa, key, m);
    return m;
}

pub fn fetch(self: *@This(), io: std.Io, artifact: []const u8) !void {
    const l = log(.artifact_fetch);
    if (Weft.is_source_artifact(artifact)) {
        const artifact_path = try self.project.artifact_dir_path(self.gpa, io, self.dep.id, artifact);
        defer self.gpa.free(artifact_path);
        return std.Io.Dir.cwd().access(io, artifact_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                l.err("Source artifact {s} couldn't be found", .{artifact});
                return error.InvalidSourceArtifact;
            } else return err;
        };
    }

    const m = try self.get_mutex(io, &self.pulling, artifact);
    try m.lock(io);
    defer m.unlock(io);

    const artifact_path = try self.project.artifact_dir_path(self.gpa, io, self.dep.id, artifact);
    defer self.gpa.free(artifact_path);

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

    const push_id = try std.mem.join(self.gpa, ".", &.{ remote.@"0", artifact });
    defer self.gpa.free(push_id);

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

    const artifact_dir_path = try self.project.artifact_dir_path(self.gpa, io, self.dep.id, artifact);
    defer self.gpa.free(artifact_dir_path);

    var client = try Client.connect(self.gpa, io, try Weft.parse_remote_address(io, remote.*), self.identity);
    defer client.destroy(self.gpa, io);

    const task_id: proto.task.Id = .{
        .deployment = self.dep.id,
        .pipeline = artifact,
        .workspace = self.dep.config.workspace,
    };

    try transfer.push_dir(
        self.gpa,
        io,
        &client.conn,
        task_id,
        artifact_dir_path,
        self.state,
        remote,
        artifact,
    );
}

pub fn pull_artifact(self: *@This(), io: std.Io, artifact: []const u8) !void {
    const remote: *const Remote = remote: {
        try self.depl.lock(io);
        defer self.depl.unlock(io);
        for (self.dep.artifacts) |*art| {
            if (std.mem.eql(u8, art.name, artifact))
                for (self.remotes) |*rem|
                    if (std.mem.eql(u8, rem.@"0", art.remote))
                        break :remote rem;
        } else return error.ArtifactNotFound;
    };

    try self.state.artifact_progress(io, artifact, remote, .pulling, 0.0);
    defer self.state.artifact_progress(io, artifact, remote, .ready, 1.0) catch {};

    var client = try Client.connect(self.gpa, io, try Weft.parse_remote_address(io, remote.*), self.identity);
    defer client.destroy(self.gpa, io);

    const artifact_path = try self.project.artifact_dir_path(self.gpa, io, self.dep.id, artifact);
    defer self.gpa.free(artifact_path);

    const task_id: proto.task.Id = .{
        .deployment = self.dep.id,
        .pipeline = artifact,
        .workspace = self.dep.config.workspace,
    };

    try transfer.pull_dir(
        self.gpa,
        io,
        &client.conn,
        task_id,
        artifact_path,
        self.state,
        remote,
        artifact,
    );
}

pub fn spawn_fetch(self: *@This(), io: std.Io, artifact: []const u8) !void {
    const key = try self.gpa.dupe(u8, artifact);
    errdefer self.gpa.free(key);

    try spawn(io, &self.group, fetch_wrapper, .{ self, io, key });
}

fn fetch_wrapper(self: *@This(), io: std.Io, key: []const u8) !void {
    const l = log(.artifact_fetch);
    defer self.gpa.free(key);

    for (0..3) |attempt| {
        if (attempt > 0)
            std.Io.sleep(io, .fromSeconds(1), .awake) catch {};

        self.fetch(io, key) catch |err| {
            if (attempt < 2)
                continue;

            l.err("failed to fetch artifact {s}: {any}", .{ key, err });
            return;
        };

        return;
    }
}

pub fn is_idle(self: *@This(), io: std.Io) bool {
    self.state.mutex.lockUncancelable(io);
    defer self.state.mutex.unlock(io);

    return for (self.state.artifacts.items) |art| {
        if (art.status == .pulling or art.status == .pushing)
            break false;
    } else true;
}
