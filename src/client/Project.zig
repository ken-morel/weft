const std = @import("std");

const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const Deployment = @import("Deployment.zig");

dir: std.Io.Dir,

pub inline fn open(dir: std.Io.Dir) !@This() {
    return .{
        .dir = dir,
    };
}

pub fn get_config(self: @This(), alloc: std.mem.Allocator, term: ?*Term, io: std.Io) !Weft {
    @setEvalBranchQuota(100_000);
    const content = self.dir.readFileAllocOptions(
        io,
        "weft.zon",
        alloc,
        .limited(64 << 10),
        .of(u8),
        0,
    ) catch |err|
        if (err == error.FileNotFound)
            return error.ConfigNotFound
        else
            return err;
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(alloc);
    return std.zon.parse.fromSliceAlloc(Weft, alloc, content, &diag, .{}) catch |err| {
        if (term) |t|
            diag.format(t.writer()) catch {};
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

    weft_dir.createDirPath(
        io,
        &deployment_name,
    ) catch |err|
        if (err != error.PathAlreadyExists)
            return err;

    return weft_dir.openDir(io, &deployment_name, .{ .iterate = true });
}

pub fn artifact_dir_path(self: @This(), alloc: std.mem.Allocator, io: std.Io, deployment_id: Deployment.Id, pipeline: []const u8) ![]const u8 {
    const deployment_dir = try self.open_deployment_dir(io, deployment_id);
    defer deployment_dir.close(io);

    const deployment_dir_path = try deployment_dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(deployment_dir_path);

    return try std.fs.path.join(
        alloc,
        &.{ deployment_dir_path, "artifacts", pipeline },
    );
}

pub fn task_log_path(self: @This(), alloc: std.mem.Allocator, io: std.Io, deployment_id: Deployment.Id, pipeline: []const u8) ![]const u8 {
    const deployment_dir = try self.open_deployment_dir(io, deployment_id);
    defer deployment_dir.close(io);

    const deployment_dir_path = try deployment_dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(deployment_dir_path);

    const log_name = try std.fmt.allocPrint(alloc, "{s}.log", .{pipeline});
    defer alloc.free(log_name);

    return try std.fs.path.join(
        alloc,
        &.{ deployment_dir_path, "logs", log_name },
    );
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

    return match.?;
}

pub fn load_deployment(self: @This(), alloc: std.mem.Allocator, io: std.Io, id: Deployment.Id) !Deployment {
    @setEvalBranchQuota(100_000);
    var dep_dir = try self.open_deployment_dir(io, id);
    defer dep_dir.close(io);

    var iter = dep_dir.iterate();
    var content: ?[]u8 = null;
    defer if (content) |c| alloc.free(c);

    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zon")) {
            var file = try dep_dir.openFile(io, entry.name, .{});
            defer file.close(io);
            var buffer: [1 << 10]u8 = undefined;
            var reader = file.reader(io, &buffer);
            content = try reader.interface.allocRemaining(alloc, .limited(512 << 10));
            break;
        }
    }

    const zon_content = content orelse return error.DeploymentNotFound;
    const null_terminated = try alloc.dupeSentinel(u8, zon_content, 0);
    defer alloc.free(null_terminated);

    var deployment = try std.zon.parse.fromSliceAlloc(Deployment, alloc, null_terminated, null, .{});
    deployment.id = id;
    deployment.running = &.{};
    return deployment;
}
