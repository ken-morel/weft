const std = @import("std");

const Task = @import("../daemon/Task.zig");
const nix = @import("../nix/nix.zig");
const zoto = @import("../util/zoto.zig");

pub fn spawn(io: std.Io, run_dir_path: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{
            "/proc/self/exe",
            "daemon",
            "supervise",
            run_dir_path,
        },
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |s| if (s != 0)
            error.SpawnFailed
        else
            {},
        else => error.SpawnFailed,
    };
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, task: Task) !void {
    _ = std.os.linux.syscall3(.setpriority, 0, 0, 10);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cwd: std.Io.Dir = .cwd();

    const run_dir_path = try task.run_dir_path(alloc);
    const archive_dir_path = try task.archive_dir_path(alloc);
    const archive_dir = try cwd.openDir(io, archive_dir_path, .{});

    const l = l: {
        const log_file = try archive_dir.createFile(io, "log.txt", .{ .truncate = false });
        defer log_file.close(io);
        _ = std.os.linux.dup2(log_file.handle, std.posix.STDOUT_FILENO);
        _ = std.os.linux.dup2(log_file.handle, std.posix.STDERR_FILENO);
        break :l std.log.scoped(.supervisor);
    };

    l.info("supervisor initialized (nice +10)", .{});
    l.debug("reading {s}/spec...", .{run_dir_path});
    const spec = try task.read_spec(gpa, alloc, io);

    const skip = handle_siblings: {
        l.info("resolving sibling policies...", .{});

        const do_sibling = spec.sibling;
        if (do_sibling.poll == 0) {
            l.err("task has invalid sibling.poll of {d}", .{do_sibling.poll});
            return error.InvalidSiblingConfig;
        }

        var waited: u32 = 0;
        while (waited < do_sibling.wait) : (waited += do_sibling.poll) {
            var sibling_iter = try task.siblings(gpa, io, false);
            defer sibling_iter.deinit(io);
            const sibling: Task = while (try sibling_iter.next(io)) |sibl| {
                if (try sibl.is_active(gpa, io))
                    break sibl;
            } else break;

            const cgroup_name = try sibling.cgroup_name(gpa);
            defer gpa.free(cgroup_name);
            l.warn("waiting {d}s for active sibling {s}...", .{ do_sibling.wait - waited, cgroup_name });
            try std.Io.sleep(io, .fromSeconds(do_sibling.poll), .awake);
        }

        switch (spec.sibling.then) {
            .ignore => {},
            .kill => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);
                while (try siblings.next(io)) |sibling| {
                    if (try sibling.is_active(gpa, io)) {
                        const name = try sibling.cgroup_name(gpa);
                        defer gpa.free(name);
                        l.info("killing active sibling {s}", .{name});
                        try sibling.kill(gpa, io);
                    }
                }
            },
            .fail => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);
                while (try siblings.next(io)) |sibling| {
                    if (try sibling.is_active(gpa, io)) {
                        l.err("sibling is still active after timeout; failing task", .{});
                        return error.AlreadyRunning;
                    }
                }
            },
            .skip => {
                var siblings = try task.siblings(gpa, io, false);
                defer siblings.deinit(io);
                break :handle_siblings while (try siblings.next(io)) |sibling| {
                    if (try sibling.is_active(gpa, io)) {
                        l.info("sibling is active; skipping task", .{});
                        break true;
                    }
                } else false;
            },
        }
        break :handle_siblings false;
    };

    if (skip) {
        l.info("task skipped", .{});
        return;
    }

    handle_packages: {
        if (spec.pkgs.len > 0) {
            l.info("preparing {d} nix package(s)...", .{spec.pkgs.len});
            var client: std.http.Client = .{
                .io = io,
                .allocator = alloc,
            };
            defer client.deinit();

            for (spec.pkgs) |pkg| {
                try nix.install_package(alloc, io, &client, pkg);
            }
            l.info("all nix packages prepared", .{});
        }
        break :handle_packages;
    }
}
