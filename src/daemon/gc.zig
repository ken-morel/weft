const std = @import("std");
const Deployment = @import("../client/Deployment.zig");
const paths = @import("../domain/paths.zig");
const Term = @import("../domain/Term.zig");
const Task = @import("Task.zig");

pub const GcOptions = struct {
    workspace: ?[]const u8 = null,
    keep: ?u32 = null,
    older_than_ms: ?u64 = null,
    dry_run: bool = false,
};

pub const GcResult = struct {
    deployments_removed: u32 = 0,
    bytes_freed: u64 = 0,
};

pub fn parse_duration(str: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, str, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.endsWith(u8, trimmed, "ms"))
        return std.fmt.parseInt(u64, trimmed[0 .. trimmed.len - 2], 10) catch null;
    const last = trimmed[trimmed.len - 1];
    const num_str = switch (last) {
        'd', 'D', 'h', 'H', 'm', 'M', 's', 'S' => trimmed[0 .. trimmed.len - 1],
        '0'...'9' => trimmed,
        else => return null,
    };
    const val = std.fmt.parseInt(u64, num_str, 10) catch return null;
    const mult: u64 = switch (last) {
        'd', 'D' => 86400 * 1000,
        'h', 'H' => 3600 * 1000,
        'm', 'M' => 60 * 1000,
        else => 1000,
    };
    return val * mult;
}

fn calc_dir_size(io: std.Io, dir: std.Io.Dir) u64 {
    var size: u64 = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        switch (entry.kind) {
            .file => {
                if (dir.statFile(io, entry.name, .{}) catch null) |st|
                    size += st.size;
            },
            .directory => {
                if (dir.openDir(io, entry.name, .{ .iterate = true }) catch null) |sub| {
                    defer sub.close(io);
                    size += calc_dir_size(io, sub);
                }
            },
            else => {},
        }
    }
    return size;
}

fn calc_path_size(io: std.Io, path: []const u8) u64 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    return calc_dir_size(io, dir);
}

fn is_deployment_active(io: std.Io, alloc: std.mem.Allocator, workspace: []const u8, dep_id: Deployment.Id) bool {
    const dep_str = dep_id.to_string();
    const ws_run_path = std.fs.path.join(alloc, &.{ paths.weft_run_dir, workspace }) catch return false;
    defer alloc.free(ws_run_path);

    var ws_dir = std.Io.Dir.cwd().openDir(io, ws_run_path, .{ .iterate = true }) catch return false;
    defer ws_dir.close(io);

    var iter = ws_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const dep_run_path = std.fs.path.join(alloc, &.{ ws_run_path, entry.name, &dep_str }) catch continue;
        defer alloc.free(dep_run_path);
        std.Io.Dir.cwd().access(io, dep_run_path, .{}) catch continue;

        const task: Task = .{ .id = .{
            .workspace = workspace,
            .deployment = dep_id,
            .pipeline = entry.name,
        } };
        if (task.is_active(alloc, io) catch false) return true;
    }
    return false;
}

fn clean_tmp(io: std.Io, alloc: std.mem.Allocator, dry_run: bool) u64 {
    var tmp_dir = std.Io.Dir.cwd().openDir(io, paths.weft_tmp_dir, .{ .iterate = true }) catch return 0;
    defer tmp_dir.close(io);

    var freed: u64 = 0;
    var iter = tmp_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const full_path = std.fs.path.join(alloc, &.{ paths.weft_tmp_dir, entry.name }) catch continue;
        defer alloc.free(full_path);
        const sz = calc_path_size(io, full_path);
        freed += sz;
        if (!dry_run)
            std.Io.Dir.cwd().deleteTree(io, full_path) catch {};
    }
    return freed;
}

const DepEntry = struct {
    dep_id: Deployment.Id,
    timestamp_ms: u64,
};

fn dep_desc(_: void, a: DepEntry, b: DepEntry) bool {
    return a.dep_id.raw > b.dep_id.raw;
}

pub fn run(alloc: std.mem.Allocator, io: std.Io, term: ?*Term, opts: GcOptions) !GcResult {
    _ = term;
    paths.ensure_dirs(io);

    var res: GcResult = .{};
    const now_ms = @as(u64, @intCast(std.Io.Clock.now(.real, io).toMilliseconds()));
    const keep_count = opts.keep orelse 5;

    var art_dir = std.Io.Dir.cwd().openDir(io, paths.weft_artifacts_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return res;
        return err;
    };
    defer art_dir.close(io);

    var ws_iter = art_dir.iterate();
    while (try ws_iter.next(io)) |ws_entry| {
        if (ws_entry.kind != .directory) continue;
        if (opts.workspace) |w| {
            if (!std.mem.eql(u8, w, ws_entry.name)) continue;
        }

        var ws_dir = art_dir.openDir(io, ws_entry.name, .{ .iterate = true }) catch continue;
        defer ws_dir.close(io);

        var deps: std.ArrayList(DepEntry) = .empty;
        defer deps.deinit(alloc);

        var dep_iter = ws_dir.iterate();
        while (try dep_iter.next(io)) |dep_e| {
            if (dep_e.kind != .directory) continue;
            const dep_id = Deployment.Id.parse(dep_e.name) catch continue;
            const ts_ms = 1_767_225_600_000 + ((dep_id.raw >> 15) * 100);
            try deps.append(alloc, .{ .dep_id = dep_id, .timestamp_ms = ts_ms });
        }

        std.mem.sort(DepEntry, deps.items, {}, dep_desc);

        for (deps.items, 0..) |dep, idx| {
            var should_delete = idx >= keep_count;
            if (opts.older_than_ms) |older_ms| {
                if (now_ms > dep.timestamp_ms) {
                    const age = now_ms - dep.timestamp_ms;
                    if (age >= older_ms)
                        should_delete = true
                    else if (idx < keep_count)
                        should_delete = false;
                }
            }

            if (!should_delete) continue;
            if (is_deployment_active(io, alloc, ws_entry.name, dep.dep_id)) continue;

            const dep_str = dep.dep_id.to_string();

            var dep_size: u64 = 0;
            const art_path = try std.fs.path.join(alloc, &.{ paths.weft_artifacts_dir, ws_entry.name, &dep_str });
            defer alloc.free(art_path);
            dep_size += calc_path_size(io, art_path);

            const arc_path = try std.fs.path.join(alloc, &.{ paths.weft_archive, ws_entry.name, &dep_str });
            defer alloc.free(arc_path);
            dep_size += calc_path_size(io, arc_path);

            if (!opts.dry_run) {
                std.Io.Dir.cwd().deleteTree(io, art_path) catch {};
                std.Io.Dir.cwd().deleteTree(io, arc_path) catch {};
            }

            res.deployments_removed += 1;
            res.bytes_freed += dep_size;
        }
    }

    res.bytes_freed += clean_tmp(io, alloc, opts.dry_run);
    return res;
}
