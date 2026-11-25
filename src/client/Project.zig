const std = @import("std");
const log = std.log.scoped;

const DotEnv = @import("../domain/DotEnv.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const zoton = @import("../util/zoton.zig");
const Deployment = @import("Deployment.zig");

dir: std.Io.Dir,
env: DotEnv,

pub fn open_leaky(ara: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !@This() {
    return .{
        .dir = dir,
        .env = try .load_leaky(ara, io, dir),
    };
}

pub fn resolve_deployment_id(self: @This(), io: std.Io, spec: ?[]const u8) !Deployment.Id {
    const l = log(.resolve_deployment);
    return if (spec) |dep_str|
        self.find_deployment_id(io, dep_str) catch |err| {
            l.err("deployment '{s}' not found or ambiguous: {any}", .{ dep_str, err });
            return error.InvalidDeploymentId;
        }
    else
        try self.latest_deployment_id(io) orelse {
            l.err("no deployments found", .{});
            return error.NoDeployments;
        };
}

pub fn get_config_leaky(self: @This(), ara: std.mem.Allocator, io: std.Io) !Weft {
    const content = self.dir.readFileAllocOptions(
        io,
        "weft/weft.zon",
        ara,
        .unlimited,
        .of(u8),
        0,
    ) catch |err|
        if (err == error.FileNotFound)
            return error.ConfigNotFound
        else
            return err;
    return try zoton.deserialize_leaky(ara, ara, content, Weft);
}

pub inline fn open_deployments_dir(self: @This(), io: std.Io) !std.Io.Dir {
    return self.dir.createDirPathOpen(io, "weft/do", .{ .open_options = .{ .iterate = true } });
}
pub fn open_deployment_dir(self: @This(), io: std.Io, deployment: Deployment.Id) !std.Io.Dir {
    const deployments_dir = try self.open_deployments_dir(io);
    defer deployments_dir.close(io);

    const deployment_name = deployment.to_string();

    return try deployments_dir.createDirPathOpen(
        io,
        &deployment_name,
        .{ .open_options = .{ .iterate = true } },
    );
}

pub fn artifact_dir_path(self: @This(), gpa: std.mem.Allocator, io: std.Io, deployment_id: Deployment.Id, pipeline: []const u8) ![]const u8 {
    const deployment_dir = try self.open_deployment_dir(io, deployment_id);
    defer deployment_dir.close(io);

    const deployment_dir_path = try deployment_dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(deployment_dir_path);

    return try std.fs.path.join(
        gpa,
        &.{ deployment_dir_path, pipeline },
    );
}
pub fn cache_dir_path(self: @This(), gpa: std.mem.Allocator, io: std.Io, remote: []const u8, cache: ?[]const u8) ![:0]const u8 {
    const project_path = try self.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(project_path);

    return try std.fs.path.joinZ(gpa, if (cache) |c| &.{
        project_path,
        "weft",
        "cache",
        remote,
        c,
    } else &.{
        project_path,
        "weft",
        "cache",
        remote,
    });
}

pub fn latest_deployment_id(self: @This(), io: std.Io) !?Deployment.Id {
    var deployments_dir = self.open_deployments_dir(io) catch |err|
        if (err == error.FileNotFound)
            return null
        else
            return err;
    defer deployments_dir.close(io);

    var iter = deployments_dir.iterate();
    var latest: ?Deployment.Id = null;
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory)
            continue;
        const id = Deployment.Id.parse(entry.name) catch continue;
        if (latest) |curr| {
            if (id.gt(curr))
                latest = id;
        } else latest = id;
    }
    return latest;
}

pub fn find_deployment_id(self: @This(), io: std.Io, query: []const u8) !Deployment.Id {
    if (Deployment.Id.parse(query)) |id|
        return id
    else |_| {}

    if (query.len < 2)
        return error.QueryTooShort;

    var deployments_dir = try self.open_deployments_dir(io);
    defer deployments_dir.close(io);

    var iter = deployments_dir.iterate();
    var match: ?Deployment.Id = null;
    var count: usize = 0;

    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory)
            continue;
        const id = Deployment.Id.parse(entry.name) catch continue;
        if (std.mem.endsWith(u8, entry.name, query)) {
            match = id;
            count += 1;
        }
    }

    if (count == 0)
        return error.DeploymentNotFound;
    if (count > 1)
        return error.AmbiguousDeploymentId;

    return match orelse unreachable;
}
pub fn unique_deployment_id_chars(self: @This(), io: std.Io, dep: Deployment.Id) u8 {
    var deployments_dir = try self.open_deployments_dir(io);
    defer deployments_dir.close(io);

    const dep_str = dep.to_string();
    var pos = 6;

    var iter = deployments_dir.iterate();

    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory or std.mem.eql(entry.name, &dep_str))
            continue;
        _ = Deployment.Id.parse(entry.name) catch continue;
        while (std.mem.endsWith(u8, entry.name, dep_str[pos..]))
            pos -= 1;
    }
    return dep_str.len - pos;
}

pub fn load_deployment_leaky(self: @This(), gpa: std.mem.Allocator, ara: std.mem.Allocator, io: std.Io, id: Deployment.Id) !Deployment {
    const l = log(.load_deployment);
    var dep_dir = try self.open_deployment_dir(io, id);
    defer dep_dir.close(io);

    const content = dep_dir.readFileAllocOptions(io, "deployment.zon", ara, .unlimited, .of(u8), 0) catch |err| {
        if (err == error.FileNotFound) {
            l.err("Deployment {d} does not exist", .{id});
            return error.DeploymentNotFound;
        }
        return err;
    };

    return try zoton.deserialize_leaky(gpa, ara, content, Deployment);
}

pub fn locate_script_in_dir(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, name: []const u8) !?[:0]const u8 {
    const iter_dir = try dir.openDir(io, ".", .{ .iterate = true });
    defer iter_dir.close(io);
    const script_with_dot = try std.mem.join(gpa, "", &.{ name, "." });
    defer gpa.free(script_with_dot);
    var iter = iter_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and
            ((std.mem.startsWith(u8, entry.name, script_with_dot) and
                std.mem.countScalar(u8, entry.name[script_with_dot.len..], '.') == 0) or
                std.mem.eql(u8, entry.name, name)))
            return try dir.realPathFileAlloc(io, entry.name, gpa);
    } else return null;
}

pub fn locate_script(self: @This(), gpa: std.mem.Allocator, io: std.Io, name: []const u8) !?[:0]const u8 {
    var script_dir = self.dir.openDir(
        io,
        "weft",
        .{ .iterate = true },
    ) catch |err|
        return if (err == error.FileNotFound)
            null
        else
            err;
    defer script_dir.close(io);
    return locate_script_in_dir(io, script_dir, gpa, name);
}
