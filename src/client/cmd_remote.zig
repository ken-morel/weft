const std = @import("std");

const ClientInstall = @import("ClientInstall.zig");
const Remote = @import("Remote.zig");
const Term = @import("../domain/Term.zig");

const TargetInfo = struct {
    ssh_dest: []const u8,
    host: []const u8,
    port: ?[]const u8,
};

fn parse_target(alloc: std.mem.Allocator, raw: []const u8) !TargetInfo {
    var user: []const u8 = "root";
    var rest: []const u8 = raw;

    if (std.mem.indexOfScalar(u8, raw, '@')) |at_idx| {
        user = raw[0..at_idx];
        rest = raw[at_idx + 1 ..];
    }

    var host: []const u8 = rest;
    var maybe_port: ?[]const u8 = null;

    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon_idx| {
        const candidate_port = rest[colon_idx + 1 ..];
        if (candidate_port.len > 0 and (std.fmt.parseInt(u16, candidate_port, 10) catch null) != null) {
            host = rest[0..colon_idx];
            maybe_port = candidate_port;
        }
    }

    const ssh_dest = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ user, host });

    return .{
        .ssh_dest = ssh_dest,
        .host = host,
        .port = maybe_port,
    };
}

fn resolve_host(alloc: std.mem.Allocator, io: std.Io, ssh_dest: []const u8, maybe_port: ?[]const u8, fallback_host: []const u8) ![]const u8 {
    const argv: []const []const u8 = if (maybe_port) |p|
        &.{ "ssh", "-p", p, "-G", ssh_dest }
    else
        &.{ "ssh", "-G", ssh_dest };

    if (std.process.run(alloc, io, .{
        .argv = argv,
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

    return try alloc.dupe(u8, fallback_host);
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
    extra_args: []const []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const target = try parse_target(arena_alloc, ssh_target);

    const host = if (maybe_host) |h|
        h
    else
        try resolve_host(arena_alloc, io, target.ssh_dest, target.port, target.host);

    const exe_path = try std.process.executablePathAlloc(io, arena_alloc);

    term.op("uploading weft binary to {s}...", .{target.ssh_dest});
    const scp_dst = try std.fmt.allocPrint(arena_alloc, "{s}:/tmp/weft", .{target.ssh_dest});

    const scp_argv: []const []const u8 = if (target.port) |p|
        &.{ "scp", "-P", p, exe_path, scp_dst }
    else
        &.{ "scp", exe_path, scp_dst };

    var scp_child = try std.process.spawn(io, .{
        .argv = scp_argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const scp_term = try scp_child.wait(io);
    if (scp_term != .exited or scp_term.exited != 0) {
        term.err("failed to copy binary to remote (exit code {any})", .{scp_term});
        return error.ScpFailed;
    }

    term.op("installing weft daemon on {s}...", .{target.ssh_dest});
    var install_cmd: std.ArrayList([]const u8) = .empty;
    try install_cmd.append(arena_alloc, "/usr/local/bin/weft daemon install");
    for (extra_args) |arg| {
        try install_cmd.append(arena_alloc, arg);
    }
    const install_cmd_str = try std.mem.join(arena_alloc, " ", install_cmd.items);

    const remote_script = try std.fmt.allocPrint(
        arena_alloc,
        "cp /tmp/weft /usr/local/bin/weft.new && chmod +x /usr/local/bin/weft.new && mv -f /usr/local/bin/weft.new /usr/local/bin/weft && rm -f /tmp/weft && {s} && /usr/local/bin/weft daemon show-token",
        .{install_cmd_str},
    );

    const ssh_argv: []const []const u8 = if (target.port) |p|
        &.{ "ssh", "-p", p, target.ssh_dest, remote_script }
    else
        &.{ "ssh", target.ssh_dest, remote_script };

    const ssh_res = try std.process.run(arena_alloc, io, .{
        .argv = ssh_argv,
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
            .address = .{ try arena_alloc.dupe(u8, host), 9338 },
            .token = try arena_alloc.dupe(u8, token),
            .groups = &.{},
        });

    try installation.save_remotes(io, remotes_list.items);
    term.success("registered remote '{s}' at {s}:{d}", .{ name, if (updated) remotes_list.items[remotes_list.items.len - 1].address.@"0" else host, if (updated) remotes_list.items[remotes_list.items.len - 1].address.@"1" else 9338 });
}
