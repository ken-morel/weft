const std = @import("std");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");
const gc_core = @import("../daemon/gc.zig");
const Term = @import("../domain/Term.zig");
const proto = @import("../domain/proto.zig");
const format_bytes = @import("../util/sizes.zig").format_bytes;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: ?Project,
    inst: ClientInstall,
    remote_spec: ?[]const u8,
    keep: ?u32,
    older_than_str: ?[]const u8,
    dry_run: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const older_than_ms = if (older_than_str) |s| gc_core.parse_duration(s) else null;
    const remotes = inst.get_remotes(alloc, io, term) catch &.{};

    var buf: [32]u8 = undefined;

    if (remote_spec) |rem_name| {
        if (std.mem.eql(u8, rem_name, "local")) {
            const res = try gc_core.run(alloc, io, term, .{
                .keep = keep,
                .older_than_ms = older_than_ms,
                .dry_run = dry_run,
            });
            if (dry_run) {
                term.println("gc [local]: would remove {d} deployments, freeing {s}", .{
                    res.deployments_removed,
                    format_bytes(&buf, res.bytes_freed),
                });
            } else {
                term.println("gc [local]: removed {d} deployments, freed {s}", .{
                    res.deployments_removed,
                    format_bytes(&buf, res.bytes_freed),
                });
            }
            return;
        }

        const remote = for (remotes) |*r| {
            if (std.mem.eql(u8, r.get_name(), rem_name))
                break r;
        } else {
            term.err("remote '{s}' not found", .{rem_name});
            return error.RemoteNotFound;
        };

        var client = try Client.connect(alloc, io, try remote.get_address(), &try remote.get_token());
        defer client.destroy(alloc, io);

        var send_buf: [128]u8 = undefined;
        try client.conn.send_object(&send_buf, proto.Request, .gc);
        try client.conn.send_object(&send_buf, proto.gc.Req, .{
            .keep = keep,
            .older_than_ms = older_than_ms,
            .dry_run = dry_run,
        });

        const res = try try client.conn.recv_object(alloc, proto.Res(proto.gc.Res));
        if (dry_run) {
            term.println("gc [{s}]: would remove {d} deployments, freeing {s}", .{
                rem_name,
                res.deployments_removed,
                format_bytes(&buf, res.bytes_freed),
            });
        } else {
            term.println("gc [{s}]: removed {d} deployments, freed {s}", .{
                rem_name,
                res.deployments_removed,
                format_bytes(&buf, res.bytes_freed),
            });
        }
        return;
    }

    const local_res = gc_core.run(alloc, io, term, .{
        .keep = keep,
        .older_than_ms = older_than_ms,
        .dry_run = dry_run,
    }) catch |err| res: {
        term.warn("local gc failed: {any}", .{err});
        break :res gc_core.GcResult{};
    };

    if (dry_run) {
        term.println("gc [local]: would remove {d} deployments, freeing {s}", .{
            local_res.deployments_removed,
            format_bytes(&buf, local_res.bytes_freed),
        });
    } else {
        term.println("gc [local]: removed {d} deployments, freed {s}", .{
            local_res.deployments_removed,
            format_bytes(&buf, local_res.bytes_freed),
        });
    }

    for (remotes) |*remote| {
        const r_name = remote.get_name();
        if (std.mem.eql(u8, r_name, "local")) continue;

        var client = Client.connect(alloc, io, remote.get_address() catch continue, &(remote.get_token() catch continue)) catch |err| {
            term.warn("failed to connect to remote '{s}': {any}", .{ r_name, err });
            continue;
        };
        defer client.destroy(alloc, io);

        var send_buf: [128]u8 = undefined;
        client.conn.send_object(&send_buf, proto.Request, .gc) catch continue;
        client.conn.send_object(&send_buf, proto.gc.Req, .{
            .keep = keep,
            .older_than_ms = older_than_ms,
            .dry_run = dry_run,
        }) catch continue;

        const res = client.conn.recv_object(alloc, proto.Res(proto.gc.Res)) catch continue;
        if (res) |r| {
            if (dry_run) {
                term.println("gc [{s}]: would remove {d} deployments, freeing {s}", .{
                    r_name,
                    r.deployments_removed,
                    format_bytes(&buf, r.bytes_freed),
                });
            } else {
                term.println("gc [{s}]: removed {d} deployments, freed {s}", .{
                    r_name,
                    r.deployments_removed,
                    format_bytes(&buf, r.bytes_freed),
                });
            }
        } else |_| {}
    }

    if (project) |prj| {
        clean_project_weft(alloc, io, term, prj, keep orelse 5, older_than_ms, dry_run);
    }
}

fn clean_project_weft(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    keep: u32,
    older_than_ms: ?u64,
    dry_run: bool,
) void {
    var weft_dir = project.open_weft_dir(io) catch return;
    defer weft_dir.close(io);

    const DepEntry = struct {
        id: Deployment.Id,
        name: [8]u8,
        ts: u64,
    };
    var deps: std.ArrayList(DepEntry) = .empty;
    defer deps.deinit(alloc);

    var iter = weft_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const dep_id = Deployment.Id.parse(entry.name) catch continue;
        const ts = 1_767_225_600_000 + ((dep_id.raw >> 15) * 100);
        var name_buf: [8]u8 = undefined;
        @memcpy(&name_buf, entry.name[0..8]);
        deps.append(alloc, .{ .id = dep_id, .name = name_buf, .ts = ts }) catch continue;
    }

    std.mem.sort(DepEntry, deps.items, {}, struct {
        fn less(_: void, a: DepEntry, b: DepEntry) bool {
            return a.id.raw > b.id.raw;
        }
    }.less);

    const now_ms = @as(u64, @intCast(std.Io.Clock.now(.real, io).toMilliseconds()));
    var removed: u32 = 0;
    for (deps.items, 0..) |dep, idx| {
        var del = idx >= keep;
        if (older_than_ms) |older| {
            if (now_ms > dep.ts) {
                if (now_ms - dep.ts >= older)
                    del = true
                else if (idx < keep)
                    del = false;
            }
        }
        if (!del) continue;
        if (!dry_run) {
            weft_dir.deleteTree(io, &dep.name) catch continue;
        }
        removed += 1;
    }
    if (removed > 0) {
        if (dry_run)
            term.println("gc [.weft]: would remove {d} local deployment directories", .{removed})
        else
            term.println("gc [.weft]: removed {d} local deployment directories", .{removed});
    }
}
