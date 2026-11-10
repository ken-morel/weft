const std = @import("std");

const Weft = @import("../domain/Weft.zig");
const ClientInstall = @import("ClientInstall.zig");
const Project = @import("Project.zig");

const log = std.log.scoped(.remotes);

pub const Remote = @This();

name: []const u8,
address: []const u8,
groups: []const u8,

pub fn has_group(self: @This(), group: []const u8) bool {
    var iter = std.mem.splitScalar(u8, self.groups, ' ');
    return while (iter.next()) |item| {
        if (item.len > 0 and std.mem.eql(u8, item, group))
            break true;
    } else false;
}

pub fn matches_group(self: @This(), group: []const u8) bool {
    return self.has_group(group);
}

pub fn find(remotes: []const @This(), name: []const u8) ?@This() {
    return for (remotes) |r| {
        if (std.mem.eql(u8, r.name, name))
            break r;
    } else null;
}

pub fn resolve_remotes_leaky(
    gpa: std.mem.Allocator,
    ara: std.mem.Allocator,
    io: std.Io,
    config: Weft,
    client_inst: *const ClientInstall,
    project: ?Project,
) ![]const @This() {
    const client_cfg = client_inst.read_config_leaky(gpa, ara, io) catch |err| blk: {
        log.warn("failed to read client.zon: {any}", .{err});
        break :blk ClientInstall.Config{};
    };

    const has_local = for (config.remotes) |r| {
        if (std.mem.eql(u8, r.@"0", "local"))
            break true;
    } else false;

    const total_len = config.remotes.len + if (has_local) @as(usize, 0) else 1;
    var resolved = try ara.alloc(@This(), total_len);
    var out_idx: usize = 0;

    for (config.remotes) |r| {
        resolved[out_idx] = try resolve_single_remote_leaky(gpa, ara, io, r, client_cfg, client_inst, project);
        out_idx += 1;
    }

    if (!has_local) {
        resolved[out_idx] = try resolve_single_remote_leaky(
            gpa,
            ara,
            io,
            Weft.remote_local,
            client_cfg,
            client_inst,
            project,
        );
        out_idx += 1;
    }

    return resolved;
}

pub fn resolve_single_remote_leaky(
    gpa: std.mem.Allocator,
    ara: std.mem.Allocator,
    io: std.Io,
    r: Weft.Remote,
    client_cfg: ClientInstall.Config,
    client_inst: *const ClientInstall,
    project: ?Project,
) !@This() {
    _ = gpa;
    const raw_addr: []const u8 = if (r.@"1") |addr|
        addr
    else blk: {
        for (client_cfg.remotes) |cr|
            if (std.mem.eql(u8, cr.@"0", r.@"0"))
                break :blk cr.@"1";
        if (std.mem.eql(u8, r.@"0", "local"))
            break :blk "127.0.0.1:9338";
        log.err("remote '{s}' has no address in weft.zon and was not found in client.zon", .{r.@"0"});
        return error.UnresolvedRemote;
    };

    const final_addr = if (raw_addr.len > 0 and raw_addr[0] == '!') blk: {
        const cmd_str = std.mem.trim(u8, raw_addr[1..], " \t\r\n");
        var iter = std.mem.splitScalar(u8, cmd_str, ' ');
        const script_name = iter.next() orelse raw_addr;
        const rest = cmd_str[script_name.len..];

        const resolved_path = if (try client_inst.locate_script(ara, io, script_name)) |sp|
            sp
        else if (project) |p|
            try p.locate_script(ara, io, script_name)
        else
            null;

        if (resolved_path) |sp|
            break :blk try std.fmt.allocPrint(ara, "!{s}{s}", .{ sp, rest })
        else
            break :blk raw_addr;
    } else raw_addr;

    return .{
        .name = r.@"0",
        .address = final_addr,
        .groups = r.@"2",
    };
}
