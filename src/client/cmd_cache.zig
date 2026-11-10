const std = @import("std");
const log = std.log.scoped;

const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const Remote = @import("Remote.zig").Remote;
const client_remote = @import("Remote.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Project = @import("Project.zig");
const transfer = @import("transfer.zig");
const View = @import("View.zig");

const Target = struct {
    remote: []const u8,
    cache: ?[]const u8,
};

fn parse_target(spec: []const u8) !Target {
    const dot = std.mem.indexOfScalar(u8, spec, '.');
    if (dot) |idx| {
        const remote = spec[0..idx];
        const cache = spec[idx + 1 ..];
        if (remote.len == 0 or cache.len == 0)
            return error.InvalidTarget
        else
            return .{
                .remote = remote,
                .cache = cache,
            };
    } else if (spec.len == 0)
        return error.InvalidTarget
    else
        return .{
            .remote = spec,
            .cache = null,
        };
}

fn find_remote(remotes: []const Remote, name: []const u8) ?*const Remote {
    for (remotes) |*rem| {
        if (std.mem.eql(u8, rem.name, name))
            return rem;
    }
    return null;
}

fn get_config_caches(alloc: std.mem.Allocator, config: Weft) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(alloc);

    for (config.pipelines) |p| {
        for (p.keep) |k| {
            const already_has = for (list.items) |item| {
                if (std.mem.eql(u8, item, k.@"0"))
                    break true;
            } else false;

            if (!already_has)
                try list.append(alloc, k.@"0");
        }
    }
    return try list.toOwnedSlice(alloc);
}

fn local_cache_exists(io: std.Io, project: Project, alloc: std.mem.Allocator, remote: []const u8, cache: []const u8) !bool {
    const rel_path = try std.fs.path.join(alloc, &.{ ".weft", "caches", remote, cache });
    defer alloc.free(rel_path);

    var dir = project.dir.openDir(io, rel_path, .{}) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir)
            return false
        else
            return err;
    };
    dir.close(io);
    return true;
}

fn get_local_caches(alloc: std.mem.Allocator, io: std.Io, project: Project, remote: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(alloc);

    const rel_path = try std.fs.path.join(alloc, &.{ ".weft", "caches", remote });
    defer alloc.free(rel_path);

    var dir = project.dir.openDir(io, rel_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir)
            return &.{}
        else
            return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry|
        if (entry.kind == .directory)
            try list.append(alloc, try alloc.dupe(u8, entry.name));
    return try list.toOwnedSlice(alloc);
}

pub fn path(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    source: []const u8,
) !void {
    const l = log(.cache);
    const target = parse_target(source) catch |err| {
        l.err("invalid cache target '{s}': expected <remote> or <remote>.<cache>", .{source});
        return err;
    };

    const cache_path = try project.cache_dir_path(gpa, io, target.remote, target.cache);
    defer gpa.free(cache_path);

    term.println("{s}", .{cache_path});
}

pub fn pull(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    config: Weft,
    inst: *const ClientInstall,
    source: []const u8,
    env: ?*std.process.Environ.Map,
) !void {
    const l = log(.cache);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target = parse_target(source) catch |err| {
        l.err("invalid cache target '{s}': expected <remote> or <remote>.<cache>", .{source});
        return err;
    };

    const remotes = try client_remote.resolve_remotes_leaky(gpa, alloc, io, config, inst, project);
    const remote = find_remote(remotes, target.remote) orelse {
        l.err("remote '{s}' not found", .{target.remote});
        return error.InvalidRemote;
    };

    const caches: []const []const u8 = if (target.cache) |c|
        &.{c}
    else caches: {
        const cfg_caches = try get_config_caches(alloc, config);
        if (cfg_caches.len == 0) {
            l.warn("no caches configured for workspace '{s}'", .{config.workspace});
            return;
        } else
            break :caches cfg_caches;
    };

    var clients: *Client.Manager = try .create(gpa, project, inst.identity, env);
    defer clients.destroy(io);

    var view: View = .init(gpa, term, null);
    view.auto_update = true;
    defer view.deinit();

    const managed = try clients.connect_str(io, remote.address);
    defer managed.release(io);
    const client = managed.inner;

    for (caches) |cache_name| {
        const local_path = try project.cache_dir_path(alloc, io, target.remote, cache_name);
        defer alloc.free(local_path);

        try view.set_transfer(io, cache_name, target.remote, .pulling, 0.0);

        transfer.pull_cache(
            gpa,
            io,
            &client.conn,
            .{ .workspace = config.workspace, .name = cache_name },
            local_path,
            &view,
            target.remote,
            cache_name,
        ) catch |err| {
            if (err == error.FileNotFound or err == error.ArtifactNotFound) {
                l.err("cache '{s}' not found on remote '{s}'", .{ cache_name, target.remote });
                return error.CacheNotFound;
            } else
                return err;
        };

        try view.set_transfer(io, cache_name, target.remote, .ready, 1.0);
        term.success("Pulled {s}@{s}", .{ cache_name, target.remote });
    }
}

pub fn push(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    config: Weft,
    inst: *const ClientInstall,
    source: []const u8,
    dest: ?[]const u8,
    env: ?*std.process.Environ.Map,
) !void {
    const l = log(.cache);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = parse_target(source) catch |err| {
        l.err("invalid source target '{s}': expected <remote> or <remote>.<cache>", .{source});
        return err;
    };

    const dst = if (dest) |d|
        parse_target(d) catch |err| {
            l.err("invalid destination target '{s}': expected <remote> or <remote>.<cache>", .{d});
            return err;
        }
    else
        Target{
            .remote = src.remote,
            .cache = src.cache,
        };

    const remotes = try client_remote.resolve_remotes_leaky(gpa, alloc, io, config, inst, project);
    const dst_remote = find_remote(remotes, dst.remote) orelse {
        l.err("destination remote '{s}' not found", .{dst.remote});
        return error.InvalidRemote;
    };

    if (src.cache == null and dst.cache != null) {
        l.err("cannot push all caches from '{s}' to a single cache name '{s}'", .{ src.remote, dst.cache orelse unreachable });
        return error.InvalidTarget;
    }

    if (src.cache) |src_cache_name| {
        const dst_cache_name = if (dst.cache) |dc|
            dc
        else
            src_cache_name;

        if (!try local_cache_exists(io, project, alloc, src.remote, src_cache_name)) {
            l.err("local cache '{s}.{s}' not found", .{ src.remote, src_cache_name });
            return error.CacheNotFound;
        }

        var clients: *Client.Manager = try .create(gpa, project, inst.identity, env);
        defer clients.destroy(io);

        var view: View = .init(gpa, term, null);
        view.auto_update = true;
        defer view.deinit();

        const managed = try clients.connect_str(io, dst_remote.address);
        defer managed.release(io);
        const client = managed.inner;

        const local_path = try project.cache_dir_path(alloc, io, src.remote, src_cache_name);
        defer alloc.free(local_path);

        try view.set_transfer(io, dst_cache_name, dst.remote, .pushing, 0.0);

        try transfer.push_cache(
            gpa,
            io,
            &client.conn,
            .{ .workspace = config.workspace, .name = dst_cache_name },
            local_path,
            &view,
            dst.remote,
            dst_cache_name,
        );

        try view.set_transfer(io, dst_cache_name, dst.remote, .ready, 1.0);
        term.success("Pushed {s}.{s} -> {s}.{s}", .{ src.remote, src_cache_name, dst.remote, dst_cache_name });
    } else {
        const local_caches = try get_local_caches(alloc, io, project, src.remote);
        if (local_caches.len == 0) {
            l.err("no local caches found for remote '{s}'", .{src.remote});
            return error.CacheNotFound;
        }

        var clients: *Client.Manager = try .create(gpa, project, inst.identity, env);
        defer clients.destroy(io);

        var view: View = .init(gpa, term, null);
        view.auto_update = true;
        defer view.deinit();

        const managed = try clients.connect_str(io, dst_remote.address);
        defer managed.release(io);
        const client = managed.inner;

        for (local_caches) |c_name| {
            const local_path = try project.cache_dir_path(alloc, io, src.remote, c_name);
            defer alloc.free(local_path);

            try view.set_transfer(io, c_name, dst.remote, .pushing, 0.0);

            try transfer.push_cache(
                gpa,
                io,
                &client.conn,
                .{ .workspace = config.workspace, .name = c_name },
                local_path,
                &view,
                dst.remote,
                c_name,
            );

            try view.set_transfer(io, c_name, dst.remote, .ready, 1.0);
            term.success("Pushed {s}.{s} -> {s}.{s}", .{ src.remote, c_name, dst.remote, c_name });
        }
    }
}
