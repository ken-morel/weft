const std = @import("std");

const ClientInstall = @import("ClientInstall.zig");
const Remote = @import("Remote.zig");
const Term = @import("../domain/Term.zig");

fn resolve_host(alloc: std.mem.Allocator, io: std.Io, ssh_target: []const u8) ![]const u8 {
    if (std.process.run(alloc, io, .{
        .argv = &.{ "ssh", "-G", ssh_target },
    })) |res| {
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);

        if (res.term == .exited and res.term.exited == 0) {
            var it = std.mem.splitScalar(u8, res.stdout, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (std.mem.startsWith(u8, trimmed, "hostname ")) {
                    const host = std.mem.trim(u8, trimmed["hostname ".len..], " \t\r");
                    if (host.len > 0)
                        return try alloc.dupe(u8, host);
                }
            }
        }
    } else |_| {}

    if (std.mem.indexOfScalar(u8, ssh_target, '@')) |at_idx|
        return try alloc.dupe(u8, ssh_target[at_idx + 1 ..]);
    return try alloc.dupe(u8, ssh_target);
}

fn extract_token(output: []const u8) ?[]const u8 {
    var it = std.mem.splitBackwardsScalar(u8, output, '\n');
    while (it.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "secret: "))
            line = std.mem.trim(u8, line["secret: ".len..], " \t\r");
        if (line.len == 64) {
            var all_hex = true;
            for (line) |c|
                if (!std.ascii.isHex(c)) {
                    all_hex = false;
                    break;
                };
            if (all_hex)
                return line;
        }
    }
    return null;
}

pub fn install(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    installation: ClientInstall,
    name: []const u8,
    ssh_target: []const u8,
    maybe_host: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const host = if (maybe_host) |h|
        h
    else
        try resolve_host(arena_alloc, io, ssh_target);

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

    term.op("installing and configuring weft daemon on {s}...", .{ssh_target});
    const remote_script = "cp /tmp/weft /usr/local/bin/weft.new && chmod +x /usr/local/bin/weft.new && mv -f /usr/local/bin/weft.new /usr/local/bin/weft && rm -f /tmp/weft && (test -f /etc/weft.zon || /usr/local/bin/weft daemon install) && systemctl restart weftd.service && /usr/local/bin/weft daemon show-token";

    const ssh_res = try std.process.run(arena_alloc, io, .{
        .argv = &.{ "ssh", ssh_target, remote_script },
    });
    if (ssh_res.term != .exited or ssh_res.term.exited != 0) {
        term.err("remote installation failed (exit code {any}): {s}", .{ ssh_res.term, ssh_res.stderr });
        return error.RemoteInstallFailed;
    }

    const token = extract_token(ssh_res.stdout) orelse {
        term.err("could not extract daemon token from remote output:\n{s}", .{ssh_res.stdout});
        return error.TokenNotFound;
    };

    const existing_remotes = try installation.get_remotes(arena_alloc, io, term);

    var remotes_list: std.ArrayList(Remote) = .empty;

    var updated = false;
    for (existing_remotes) |rem| {
        if (std.mem.eql(u8, rem.get_name(), name)) {
            try remotes_list.append(arena_alloc, .{
                .name = try arena_alloc.dupe(u8, name),
                .address = .{ try arena_alloc.dupe(u8, host), 9338 },
                .token = try arena_alloc.dupe(u8, token),
                .groups = rem.groups,
            });
            updated = true;
        } else {
            try remotes_list.append(arena_alloc, rem);
        }
    }

    if (!updated)
        try remotes_list.append(arena_alloc, .{
            .name = try arena_alloc.dupe(u8, name),
            .address = .{ try arena_alloc.dupe(u8, host), 9338 },
            .token = try arena_alloc.dupe(u8, token),
            .groups = &.{},
        });

    try installation.save_remotes(io, remotes_list.items);
    term.success("registered remote '{s}' at {s}:9338", .{ name, host });
}
