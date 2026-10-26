const std = @import("std");
const log = std.log.scoped;

const DotEnv = @import("../domain/DotEnv.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
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
            l.err("no deployments found in .weft", .{});
            return error.NoDeployments;
        };
}

pub fn get_config_leaky(self: @This(), ara: std.mem.Allocator, io: std.Io) !Weft {
    @setEvalBranchQuota(100_000);
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
    var diag: std.zon.parse.Diagnostics = .{
        .errors = &.{undefined},
    };
    return std.zon.parse.fromSlice(Weft, .{ .gpa = ara, .arena = ara, .source = content, .diagnostics = &diag }) catch |err| {
        diag.log("weft/weft.zon");
        return err;
    };
}

pub inline fn open_weft_dir(self: @This(), io: std.Io) !std.Io.Dir {
    return self.dir.createDirPathOpen(io, ".weft", .{ .open_options = .{ .iterate = true } });
}
pub fn open_deployment_dir(self: @This(), io: std.Io, deployment: Deployment.Id) !std.Io.Dir {
    const weft_dir = try self.open_weft_dir(io);
    defer weft_dir.close(io);

    const deployment_name = deployment.to_string();

    //TODO: Log error here
    return weft_dir.createDirPathOpen(
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
        &.{ deployment_dir_path, "artifacts", pipeline },
    );
}
pub fn cache_dir_path(self: @This(), gpa: std.mem.Allocator, io: std.Io, remote: []const u8, cache: ?[]const u8) ![]const u8 {
    const rel_path = try std.fs.path.join(gpa, if (cache) |c| &.{
        ".weft",
        "caches",
        remote,
        c,
    } else &.{
        ".weft",
        "caches",
        remote,
    });
    defer gpa.free(rel_path);
    try self.dir.createDirPath(io, rel_path);
    return try self.dir.realPathFileAlloc(io, rel_path, gpa);
}

pub fn latest_deployment_id(self: @This(), io: std.Io) !?Deployment.Id {
    var weft_dir = self.open_weft_dir(io) catch |err|
        if (err == error.FileNotFound)
            return null
        else
            return err;
    defer weft_dir.close(io);

    var iter = weft_dir.iterate();
    var latest: ?Deployment.Id = null;
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory)
            continue;
        const id = Deployment.Id.parse(entry.name) catch continue;
        if (latest) |curr| {
            if (id.raw > curr.raw)
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

    var weft_dir = try self.open_weft_dir(io);
    defer weft_dir.close(io);

    var iter = weft_dir.iterate();
    var match: ?Deployment.Id = null;
    var count: usize = 0;

    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory)
            continue;
        const id = Deployment.Id.parse(entry.name) catch continue;
        if (std.mem.endsWith(u8, entry.name, query) or std.mem.startsWith(u8, entry.name, query)) {
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

pub fn load_deployment_leaky(self: @This(), gpa: std.mem.Allocator, ara: std.mem.Allocator, io: std.Io, id: Deployment.Id) !Deployment {
    const l = log(.load_deployment);
    @setEvalBranchQuota(100_000);
    var dep_dir = try self.open_deployment_dir(io, id);
    defer dep_dir.close(io);

    const content = dep_dir.readFileAllocOptions(io, "deployment.zon", ara, .unlimited, .of(u8), 0) catch |err| {
        if (err == error.FileNotFound) {
            l.err("Deployment {d} does not exist", .{id});
            return error.DeploymentNotFound;
        }
        return err;
    };

    var diag: std.zon.parse.Diagnostics = .{ .errors = &.{undefined} };

    //TODO: Log diagnostics and errors here
    return try std.zon.parse.fromSlice(Deployment, .{ .gpa = gpa, .arena = ara, .source = content, .diagnostics = &diag });
}

pub fn locate_script(self: @This(), gpa: std.mem.Allocator, io: std.Io, name: []const u8) !?[:0]const u8 {
    const script_with_dot = try std.mem.join(gpa, "", &.{ name, "." });
    defer gpa.free(script_with_dot);
    const script_dir = self.dir.openDir(
        io,
        "weft",
        .{ .iterate = true },
    ) catch |err|
        return if (err == error.FileNotFound)
            null
        else
            err;
    defer script_dir.close(io);
    var iter = script_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and
            ((std.mem.startsWith(u8, entry.name, script_with_dot) and
                std.mem.countScalar(u8, entry.name[script_with_dot.len..], '.') == 0) or
                std.mem.eql(u8, entry.name, name)))
            return try script_dir.realPathFileAlloc(io, entry.name, gpa);
    } else return null;
}
