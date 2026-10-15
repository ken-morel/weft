const std = @import("std");
const log = std.log.scoped;

const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const Remote = Weft.Remote;
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const DeploymentState = @import("DeploymentState.zig");
const DeploymentView = @import("DeploymentView.zig");
const Project = @import("Project.zig");
const transfer = @import("transfer.zig");

fn deployment_id(io: std.Io, project: Project, deployment_spec: ?[]const u8) !Deployment.Id {
    const l = log(.artifact);
    return if (deployment_spec) |dep_str|
        project.find_deployment_id(io, dep_str) catch |err| {
            l.err("deployment '{s}' not found or ambiguous: {any}", .{ dep_str, err });
            return error.InvalidDeploymentId;
        }
    else
        try project.latest_deployment_id(io) orelse {
            l.err("no deployments found in .weft", .{});
            return error.NoDeployments;
        };
}

fn is_valid_artifact_name(name: []const u8) bool {
    return name.len > 0 and
        (std.ascii.isAlphanumeric(name[0]) or name[0] == '-') and
        for (name[1..]) |c|
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.')
                break false
            else {}
        else
            true;
}

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
) !void {
    const l = log(.artifact);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const dep_id = try deployment_id(io, project, deployment_spec);

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

    var state: DeploymentState = .init(gpa, &project);
    defer state.deinit();
    var view: DeploymentView = .init(gpa, term, &state, dep_id);
    defer view.deinit();

    const status: DeploymentState.Artifact.Status = if (direction == .pull) .pulling else .pushing;

    try state.artifact_progress(io, name, remote, status, 0.0);
    try view.update(io);

    var client = Client.connect(
        gpa,
        io,
        try Weft.parse_remote_address(remote.*),
        inst.identity,
    ) catch |err| {
        l.err("connection to remote '{s}' failed: {any}", .{ remote_name, err });
        return err;
    };
    defer client.destroy(gpa, io);

    if (direction == .push) {
        std.Io.Dir.cwd().access(io, artifact_path, .{}) catch |err| {
            if (err == error.FileNotFound)
                l.err("artifact '{s}' not found in deployment {s}", .{ name, &dep_id.to_string() })
            else
                l.err("artifact '{s}' cannot be read: {any}", .{ name, err });
            return err;
        };
        try transfer.push_dir(gpa, io, &client.conn, task_id, artifact_path, &state, remote, name);
    } else {
        transfer.pull_dir(gpa, io, &client.conn, task_id, artifact_path, &state, remote, name) catch |err| {
            if (err == error.ArtifactNotFound)
                l.err("artifact '{s}' not found on remote '{s}'", .{ name, remote_name });
            return err;
        };
    }

    try state.artifact_progress(io, name, remote, .ready, 1.0);
    try view.update(io);
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

    if (!is_valid_artifact_name(name)) {
        l.err("invalid artifact name '{s}'", .{name});
        return error.InvalidArtifactName;
    }

    const dep_id = try deployment_id(io, project, deployment_spec);
    const config = try project.get_config_leaky(alloc, io);

    const remote = config.find_remote(remote_name) orelse {
        l.err("remote '{s}' not found", .{remote_name});
        return error.InvalidRemote;
    };

    var deployment = try project.load_deployment_leaky(alloc, io, dep_id);
    try deployment.add_artifact(alloc, .{
        .remote = remote.@"0",
        .pipeline = if (config.get_producer(name)) |producer| producer.name else name,
        .name = name,
    });
    try deployment.save(alloc, io, project);

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

    if (!is_valid_artifact_name(name)) {
        l.err("invalid artifact name '{s}'", .{name});
        return error.InvalidArtifactName;
    }

    const dep_id = try deployment_id(io, project, deployment_spec);
    const artifact_path = try project.artifact_dir_path(gpa, io, dep_id, name);
    defer gpa.free(artifact_path);

    term.println("{s}", .{artifact_path});
}
