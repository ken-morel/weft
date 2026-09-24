const std = @import("std");

const Term = @import("../domain/Term.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");

pub const DeploymentSummary = struct {
    id: Deployment.Id,
    targets: []const Deployment.Step,
    artifacts_count: usize,
    failed_count: usize,
    is_completed: bool,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var weft_dir = project.open_weft_dir(io) catch |err| {
        if (err == error.FileNotFound) {
            term.println("No deployments found (.weft directory does not exist)", .{});
            return;
        }
        return err;
    };
    defer weft_dir.close(io);

    var iter = weft_dir.iterate();
    var deployments_list: std.ArrayList(DeploymentSummary) = .empty;
    defer deployments_list.deinit(alloc);

    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory)
            continue;

        const id = Deployment.Id.parse(entry.name) catch continue;
        const depl = project.load_deployment(alloc, io, id) catch continue;

        var is_done = depl.targets.len > 0;
        for (depl.targets) |t| {
            var has_art = false;
            for (depl.artifacts) |a| {
                if (std.mem.eql(u8, a.remote, t.remote) and std.mem.eql(u8, a.pipeline, t.pipeline)) {
                    has_art = true;
                    break;
                }
            }
            if (!has_art) {
                is_done = false;
                break;
            }
        }

        try deployments_list.append(alloc, .{
            .id = id,
            .targets = depl.targets,
            .artifacts_count = depl.artifacts.len,
            .failed_count = depl.failed.len,
            .is_completed = is_done,
        });
    }

    if (deployments_list.items.len == 0) {
        term.println("No deployments found in .weft", .{});
        return;
    }

    // Sort newest first (raw id descending)
    std.mem.sort(DeploymentSummary, deployments_list.items, {}, struct {
        fn lessThan(_: void, a: DeploymentSummary, b: DeploymentSummary) bool {
            return a.id.raw > b.id.raw;
        }
    }.lessThan);

    term.styled_ln(.bold, "Recent Deployments:", .{});
    for (deployments_list.items) |d| {
        const id_str = d.id.to_string();

        var targets_buf: std.ArrayList([]const u8) = .empty;
        defer targets_buf.deinit(alloc);
        for (d.targets) |t| {
            const formatted = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ t.remote, t.pipeline });
            try targets_buf.append(alloc, formatted);
        }
        const targets_str = try std.mem.join(alloc, ", ", targets_buf.items);

        const status_color: Term.Color = if (d.is_completed)
            .green
        else if (d.failed_count > 0)
            .red
        else
            .yellow;

        const status_badge: []const u8 = if (d.is_completed)
            "[DONE]   "
        else if (d.failed_count > 0)
            "[FAILED] "
        else
            "[INCOMP] ";

        term.print("  ", .{});
        term.styled(.bold, "{s}", .{&id_str});
        term.print("  ", .{});
        term.styled(status_color, "{s}", .{status_badge});
        term.println("targets: {s} (artifacts: {d})", .{
            if (targets_str.len > 0) targets_str else "(none)",
            d.artifacts_count,
        });
    }
}
