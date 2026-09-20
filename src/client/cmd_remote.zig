const std = @import("std");

const ClientInstall = @import("ClientInstall.zig");
const Remote = @import("Remote.zig");
const Term = @import("../domain/Term.zig");

pub fn install(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    installation: ClientInstall,
    name: []const u8,
    ssh_target: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const exe_path = try std.process.executablePathAlloc(io, arena_alloc);

    term.op("uploading weft binary to {s}...", .{ssh_target});
    const scp_dst = try std.fmt.allocPrint(arena_alloc, "{s}:/tmp/weft", .{ssh_target});

    var scp_child = try std.process.spawn(io, .{
        .argv = &.{ "scp", exe_path, scp_dst },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const scp_term = try scp_child.wait(io);
    if (scp_term != .exited or scp_term.exited != 0) {
        term.err("failed to copy binary to remote (exit code {any})", .{scp_term});
        return error.ScpFailed;
    }

    term.op("installing weft daemon on {s}...", .{ssh_target});
    const remote_script = "cp /tmp/weft /usr/local/bin/weft.new && chmod +x /usr/local/bin/weft.new && mv -f /usr/local/bin/weft.new /usr/local/bin/weft && rm -f /tmp/weft && /usr/local/bin/weft daemon install && /usr/local/bin/weft daemon show-token";

    const ssh_res = try std.process.run(arena_alloc, io, .{
        .argv = &.{ "ssh", ssh_target, remote_script },
    });
    if (ssh_res.term != .exited or ssh_res.term.exited != 0) {
        term.err("remote installation failed (exit code {any}): {s}", .{ ssh_res.term, ssh_res.stderr });
        return error.RemoteInstallFailed;
    }

    const token = std.mem.trim(u8, ssh_res.stdout, " \t\r\n");
    if (token.len == 0) {
        term.err("could not read daemon token from remote", .{});
        return error.TokenNotFound;
    }

    const existing_remotes = try installation.get_remotes(arena_alloc, io, term);

    var remotes_list: std.ArrayList(Remote) = .empty;
    var updated = false;

    for (existing_remotes) |rem| {
        if (std.mem.eql(u8, rem.get_name(), name)) {
            try remotes_list.append(arena_alloc, .{
                .name = try arena_alloc.dupe(u8, name),
                .address = rem.address,
                .token = try arena_alloc.dupe(u8, token),
                .groups = rem.groups,
            });
            updated = true;
        } else
            try remotes_list.append(arena_alloc, rem);
    }

    if (!updated)
        try remotes_list.append(arena_alloc, .{
            .name = try arena_alloc.dupe(u8, name),
            .address = .{ try arena_alloc.dupe(u8, ssh_target), 9338 },
            .token = try arena_alloc.dupe(u8, token),
            .groups = &.{},
        });

    try installation.save_remotes(io, remotes_list.items);
    term.success("registered remote '{s}'", .{name});
}
