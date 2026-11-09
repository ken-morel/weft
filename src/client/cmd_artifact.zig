const std = @import("std");
const log = std.log.scoped;

const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const Remote = Weft.Remote;
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const transfer = @import("transfer.zig");
const View = @import("View.zig");

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: *const ClientInstall,
    direction: enum { pull, push },
    name: []const u8,
    remote_name: []const u8,
    deployment_spec: ?[]const u8,
    env: ?*std.process.Environ.Map,
) !void {
    var clients: *Client.Manager = try .create(gpa, project, inst.identity, env);
    defer clients.destroy(io);
    const l = log(.artifact);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const dep_id = try project.resolve_deployment_id(io, deployment_spec);

    const config = try project.get_config_leaky(alloc, io);
    const remotes = try config.remotes_with_local_leaky(alloc);
    const remote: *const Remote = for (remotes) |*rem| {
        if (std.mem.eql(u8, rem.@"0", remote_name))
            break rem;
    } else {
        l.err("remote '{s}' not found", .{remote_name});
        return error.InvalidRemote;
    };

    const artifact_path = try project.artifact_dir_path(gpa, io, dep_id, name);
    defer gpa.free(artifact_path);

    const task_id: proto.task.Id = .{
        .deployment = dep_id,
        .pipeline = name,
        .workspace = config.workspace,
    };

    var depl_buf = dep_id.to_string();
    var view: View = .init(gpa, term, &depl_buf);
    view.auto_update = true;
    defer view.deinit();

    const status: View.TransferItem.Status = if (direction == .pull) .pulling else .pushing;

    try view.set_transfer(io, name, remote_name, status, 0.0);

    var managed = clients.connect_str(
        io,
        remote.@"1",
    ) catch |err| {
        l.err("connection to remote '{s}' failed: {any}", .{ remote_name, err });
        return err;
    };
    defer managed.release(io);
    const client = managed.inner;

    if (direction == .push) {
        std.Io.Dir.cwd().access(io, artifact_path, .{}) catch |err| {
            if (err == error.FileNotFound)
                l.err("artifact '{s}' not found in deployment {s}", .{ name, &dep_id.to_string() })
            else
                l.err("artifact '{s}' cannot be read: {any}", .{ name, err });
            return err;
        };
        try transfer.push_dir(gpa, io, &client.conn, task_id, artifact_path, &view, remote_name, name);
    } else {
        transfer.pull_dir(gpa, io, &client.conn, task_id, artifact_path, &view, remote_name, name) catch |err| {
            if (err == error.ArtifactNotFound)
                l.err("artifact '{s}' not found on remote '{s}'", .{ name, remote_name });
            return err;
        };
    }

    try view.set_transfer(io, name, remote_name, .ready, 1.0);
    term.success("Transferred {s}@{s}", .{ name, remote_name });
}

pub fn register(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    name: []const u8,
    remote_name: []const u8,
    deployment_spec: ?[]const u8,
) !void {
    const l = log(.artifact);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (!Weft.is_valid_artifact_name(name)) {
        l.err("invalid artifact name '{s}'", .{name});
        return error.InvalidArtifactName;
    }

    const dep_id = try project.resolve_deployment_id(io, deployment_spec);
    const config = try project.get_config_leaky(alloc, io);

    const remote = config.find_remote(remote_name) orelse {
        l.err("remote '{s}' not found", .{remote_name});
        return error.InvalidRemote;
    };

    var deployment = try project.load_deployment_leaky(gpa, alloc, io, dep_id);
    try deployment.add_artifact(alloc, .{
        .remote = remote.@"0",
        .pipeline = if (config.get_producer(name)) |producer| producer.name else name,
        .name = name,
    });
    try deployment.save(io, project);

    const artifact_path = try project.artifact_dir_path(gpa, io, dep_id, name);
    defer gpa.free(artifact_path);

    if (std.fs.path.dirname(artifact_path)) |parent|
        try std.Io.Dir.cwd().createDirPath(io, parent);

    term.println("{s}", .{artifact_path});
}

pub fn path(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    name: []const u8,
    deployment_spec: ?[]const u8,
) !void {
    const l = log(.artifact);

    if (!Weft.is_valid_artifact_name(name)) {
        l.err("invalid artifact name '{s}'", .{name});
        return error.InvalidArtifactName;
    }

    const dep_id = try project.resolve_deployment_id(io, deployment_spec);
    const artifact_path = try project.artifact_dir_path(gpa, io, dep_id, name);
    defer gpa.free(artifact_path);

    term.println("{s}", .{artifact_path});
}
