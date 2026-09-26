const std = @import("std");

const Term = @import("../domain/Term.zig");
const ClientInstall = @import("ClientInstall.zig");
const Remote = @import("Remote.zig");

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
    weft_host: ?[]const u8,
    weft_port: ?u16,
    extra_args: []const []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const target = try parse_target(arena_alloc, ssh_target);

    const host = if (weft_host) |h|
        h
    else
        try resolve_host(arena_alloc, io, target.ssh_dest, target.port, target.host);

    const port = weft_port orelse 9338;

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
    var install_argv: std.ArrayList([]const u8) = .empty;
    try install_argv.append(arena_alloc, "ssh");
    if (target.port) |p| {
        try install_argv.append(arena_alloc, "-p");
        try install_argv.append(arena_alloc, p);
    }
    try install_argv.append(arena_alloc, target.ssh_dest);
    try install_argv.append(arena_alloc, "sh");
    try install_argv.append(arena_alloc, "-c");

    const setup_script = try std.fmt.allocPrint(
        arena_alloc,
        "cp /tmp/weft /usr/local/bin/weft.new && chmod +x /usr/local/bin/weft.new && mv -f /usr/local/bin/weft.new /usr/local/bin/weft && rm -f /tmp/weft",
        .{},
    );
    try install_argv.append(arena_alloc, setup_script);

    const setup_res = try std.process.run(arena_alloc, io, .{
        .argv = install_argv.items,
    });
    if (setup_res.term != .exited or setup_res.term.exited != 0) {
        term.err("remote setup failed (exit code {any}): {s}", .{ setup_res.term, setup_res.stderr });
        return error.RemoteInstallFailed;
    }

    var daemon_argv = std.ArrayList([]const u8).init(arena_alloc);
    try daemon_argv.append(arena_alloc, "ssh");
    if (target.port) |p| {
        try daemon_argv.append(arena_alloc, "-p");
        try daemon_argv.append(arena_alloc, p);
    }
    try daemon_argv.append(arena_alloc, target.ssh_dest);
    try daemon_argv.append(arena_alloc, "/usr/local/bin/weft");
    try daemon_argv.append(arena_alloc, "daemon");
    try daemon_argv.append(arena_alloc, "install");

    for (extra_args) |arg| {
        try daemon_argv.append(arena_alloc, arg);
    }

    const daemon_res = try std.process.run(arena_alloc, io, .{
        .argv = daemon_argv.items,
    });
    if (daemon_res.term != .exited or daemon_res.term.exited != 0) {
        term.err("remote installation failed (exit code {any}): {s}", .{ daemon_res.term, daemon_res.stderr });
        return error.RemoteInstallFailed;
    }

    var token_argv = std.ArrayList([]const u8).init(arena_alloc);
    try token_argv.append(arena_alloc, "ssh");
    if (target.port) |p| {
        try token_argv.append(arena_alloc, "-p");
        try token_argv.append(arena_alloc, p);
    }
    try token_argv.append(arena_alloc, target.ssh_dest);
    try token_argv.append(arena_alloc, "/usr/local/bin/weft");
    try token_argv.append(arena_alloc, "daemon");
    try token_argv.append(arena_alloc, "token");

    const token_res = try std.process.run(arena_alloc, io, .{
        .argv = token_argv.items,
    });
    if (token_res.term != .exited or token_res.term.exited != 0) {
        term.err("remote token fetch failed (exit code {any}): {s}", .{ token_res.term, token_res.stderr });
        return error.RemoteInstallFailed;
    }

    const token = extract_token(token_res.stdout) orelse {
        term.err("could not extract daemon token from remote output:\n{s}", .{token_res.stdout});
        return error.TokenNotFound;
    };
    const existing_remotes = try installation.get_remotes(arena_alloc, io, term);

    var remotes_list: std.ArrayList(Remote) = .empty;
    var updated = false;

    for (existing_remotes) |rem| {
        if (std.mem.eql(u8, rem.get_name(), name)) {
            try remotes_list.append(arena_alloc, .{
                .name = try arena_alloc.dupe(u8, name),
                .address = if (weft_host != null or weft_port != null)
                    .{ try arena_alloc.dupe(u8, host), port }
                else
                    rem.address,
                .token = try arena_alloc.dupe(u8, token),
                .groups = rem.groups,
            });
            updated = true;
        } else try remotes_list.append(arena_alloc, rem);
    }

    if (!updated)
        try remotes_list.append(arena_alloc, .{
            .name = try arena_alloc.dupe(u8, name),
            .address = .{ try arena_alloc.dupe(u8, host), port },
            .token = try arena_alloc.dupe(u8, token),
            .groups = &.{},
        });

    try installation.save_remotes(io, remotes_list.items);
    term.success("registered remote '{s}' at {s}:{d}", .{
        name,
        if (updated) remotes_list.items[remotes_list.items.len - 1].address.@"0" else host,
        if (updated) remotes_list.items[remotes_list.items.len - 1].address.@"1" else port,
    });
}

pub fn list(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    installation: ClientInstall,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const remotes = try installation.get_remotes(arena_alloc, io, term);
    if (remotes.len == 0) {
        term.println("No remotes registered in remotes.zon", .{});
        return;
    }

    term.println("Registered remotes:", .{});
    for (remotes) |rem| {
        const name = rem.get_name();
        const host = rem.address.@"0";
        const port = rem.address.@"1";
        if (rem.groups.len > 0) {
            var groups_buf: std.ArrayList([]const u8) = .empty;
            defer groups_buf.deinit(arena_alloc);
            for (rem.groups) |g| try groups_buf.append(arena_alloc, g);
            const groups_str = try std.mem.join(arena_alloc, ", ", groups_buf.items);
            term.print("  ", .{});
            term.styled(.bold, "{s}", .{name});
            term.println(" -> {s}:{d} (groups: {s})", .{ host, port, groups_str });
        } else {
            term.print("  ", .{});
            term.styled(.bold, "{s}", .{name});
            term.println(" -> {s}:{d}", .{ host, port });
        }
    }
}

pub fn remove(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    installation: ClientInstall,
    name: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const remotes = try installation.get_remotes(arena_alloc, io, term);
    var updated_list: std.ArrayList(Remote) = .empty;
    defer updated_list.deinit(arena_alloc);

    var found = false;
    for (remotes) |rem| {
        if (std.mem.eql(u8, rem.get_name(), name)) {
            found = true;
        } else {
            try updated_list.append(arena_alloc, rem);
        }
    }

    if (!found) {
        term.err("remote '{s}' not found in remotes.zon", .{name});
        return error.RemoteNotFound;
    }

    try installation.save_remotes(io, updated_list.items);
    term.success("removed remote '{s}' from remotes.zon", .{name});
}
