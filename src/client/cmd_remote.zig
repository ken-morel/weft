const std = @import("std");
const log = std.log.scoped;

const Term = @import("../domain/Term.zig");
const ClientInstall = @import("ClientInstall.zig");

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

    const ssh_dest = try alloc.print("{s}@{s}", .{ user, host });

    return .{
        .ssh_dest = ssh_dest,
        .host = host,
        .port = maybe_port,
    };
}

fn get_remote_hostname(alloc: std.mem.Allocator, io: std.Io, target: TargetInfo) ![]const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(alloc, "ssh");
    if (target.port) |p|
        try argv.appendSlice(alloc, &.{ "-p", p });
    try argv.appendSlice(alloc, &.{ target.ssh_dest, "hostname" });

    if (std.process.run(alloc, io, .{ .argv = argv.items })) |res| {
        defer alloc.free(res.stdout);
        defer alloc.free(res.stderr);
        if (res.term == .exited and res.term.exited == 0) {
            const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
            if (trimmed.len > 0)
                return try alloc.dupe(u8, trimmed);
        }
    } else |_| {}
    return try alloc.dupe(u8, target.host);
}

pub fn register(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    inst: *const ClientInstall,
    ssh_target: []const u8,
    weft_addr: []const u8,
    maybe_pubkey: ?[]const u8,
) !void {
    const l = log(.remote_register);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target = try parse_target(alloc, ssh_target);

    const pubkey_hex: []const u8 = if (maybe_pubkey) |pk| pk else pk: {
        const client_pub = inst.identity.public_key();
        const hex = std.fmt.bytesToHex(client_pub, .lower);
        break :pk try alloc.dupe(u8, &hex);
    };

    l.info("registering client key on {s}...", .{target.ssh_dest});
    var reg_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try reg_argv.append(alloc, "ssh");
    if (target.port) |p|
        try reg_argv.appendSlice(alloc, &.{ "-p", p });
    try reg_argv.appendSlice(alloc, &.{
        target.ssh_dest,
        "/usr/local/bin/weft",
        "daemon",
        "register",
        pubkey_hex,
    });

    const reg_res = try std.process.run(alloc, io, .{
        .argv = reg_argv.items,
    });
    if (reg_res.term != .exited or reg_res.term.exited != 0) {
        l.err("remote client registration failed (exit code {any}): {s}", .{ reg_res.term, reg_res.stderr });
        return error.RemoteRegisterFailed;
    }

    const remote_name = try get_remote_hostname(alloc, io, target);

    term.println("Add this entry to your weft/weft.zon under .remotes:", .{});
    term.println("  .{{ \"{s}\", \"{s}\", \"{s}\", \"\" }},", .{ remote_name, weft_addr, ssh_target });
}

pub fn install(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    installation: *const ClientInstall,
    ssh_target: []const u8,
    weft_addr: []const u8,
    maybe_user: ?[]const u8,
    extra_args: []const []const u8,
) !void {
    const l = log(.remote_install);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target = try parse_target(alloc, ssh_target);

    const exe_path = try std.process.executablePathAlloc(io, alloc);

    term.op("uploading weft binary to {s}...", .{target.ssh_dest});
    const scp_dst = try alloc.print("{s}:/tmp/weft", .{target.ssh_dest});

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
        l.err("failed to copy binary to remote (exit code {any})", .{scp_term});
        return error.ScpFailed;
    }

    term.op("installing weft daemon on {s}...", .{target.ssh_dest});
    var install_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try install_argv.append(alloc, "ssh");
    if (target.port) |p|
        try install_argv.appendSlice(alloc, &.{ "-p", p });
    try install_argv.appendSlice(alloc, &.{
        target.ssh_dest,
        "sh -c 'cp /tmp/weft /usr/local/bin/weft.new && chmod +x /usr/local/bin/weft.new && mv -f /usr/local/bin/weft.new /usr/local/bin/weft && rm -f /tmp/weft'",
    });

    const setup_res = try std.process.run(alloc, io, .{
        .argv = install_argv.items,
    });
    if (setup_res.term != .exited or setup_res.term.exited != 0) {
        l.err("remote setup failed (exit code {any}): {s}", .{ setup_res.term, setup_res.stderr });
        return error.RemoteInstallFailed;
    }

    var daemon_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try daemon_argv.append(alloc, "ssh");
    if (target.port) |p|
        try daemon_argv.appendSlice(alloc, &.{ "-p", p });
    try daemon_argv.appendSlice(alloc, &.{
        target.ssh_dest,
        "/usr/local/bin/weft",
        "daemon",
        "install",
    });

    if (maybe_user) |user|
        try daemon_argv.appendSlice(alloc, &.{ "--user", user });
    try daemon_argv.appendSlice(alloc, extra_args);

    const daemon_res = try std.process.run(alloc, io, .{
        .argv = daemon_argv.items,
    });
    if (daemon_res.term != .exited or daemon_res.term.exited != 0) {
        l.err("remote installation failed (exit code {any}): {s}", .{ daemon_res.term, daemon_res.stderr });
        return error.RemoteInstallFailed;
    }

    return register(gpa, io, term, installation, ssh_target, weft_addr, null);
}
