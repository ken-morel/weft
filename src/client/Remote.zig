const std = @import("std");
const log = std.log.scoped;

const Weft = @import("../domain/Weft.zig");
const ClientInstall = @import("ClientInstall.zig");
const Project = @import("Project.zig");

pub const Remote = @This();

name: []const u8,
address: Address,
groups: []const u8,

pub fn has_group(self: @This(), group: []const u8) bool {
    var iter = std.mem.splitScalar(u8, self.groups, ' ');
    return while (iter.next()) |item| {
        if (item.len > 0 and std.mem.eql(u8, item, group))
            break true;
    } else false;
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
    config: ?Weft,
    inst: ?ClientInstall,
    project: ?Project,
) ![]const @This() {
    const total_len = if (config) |c|
        c.remotes.len
    else if (inst) |i|
        i.config.remotes.len
    else
        0;

    var remotes: std.ArrayList(@This()) = try .initCapacity(ara, total_len);
    defer remotes.deinit(ara);

    if (config) |c| {
        for (c.remotes) |r|
            try remotes.append(ara, try resolve_single_remote_leaky(
                gpa,
                ara,
                io,
                r,
                inst,
                project,
            ));
    } else if (inst) |i|
        for (i.config.remotes) |r|
            try remotes.append(ara, try resolve_single_remote_leaky(
                gpa,
                ara,
                io,
                .{ r.@"0", r.@"1", r.@"0" },
                inst,
                project,
            ));

    return try remotes.toOwnedSlice(ara);
}

pub fn resolve_single_remote_leaky(
    gpa: std.mem.Allocator,
    ara: std.mem.Allocator,
    io: std.Io,
    r: Weft.Remote,
    inst: ?ClientInstall,
    project: ?Project,
) !@This() {
    const l = log(.resolve_remote);
    const raw_addr = if (r.@"1") |addr|
        addr
    else if (inst) |i|
        for (i.config.remotes) |cr| {
            if (std.mem.eql(u8, cr.@"0", r.@"0"))
                break cr.@"1";
        } else null
    else
        null;

    if (raw_addr) |addr| {
        return .{
            .name = r.@"0",
            .address = try .resolve(
                gpa,
                ara,
                io,
                addr,
                inst,
                project,
            ),
            .groups = r.@"2",
        };
    } else {
        l.err("remote '{s}' has no specified address", .{r.@"0"});
        return error.InvalidRemote;
    }
}

pub const Address = union(enum) {
    ip: std.Io.net.IpAddress,
    cmd: []const []const u8,

    pub fn cmp(self: @This(), other: @This()) bool {
        const s = std.meta.activeTag(self);
        const o = std.meta.activeTag(other);
        return s == o and
            switch (s) {
                .ip => self.ip.eql(&other.ip),
                .cmd => self.cmd.len == other.cmd.len and
                    for (self.cmd, other.cmd) |a, b| {
                        if (!std.mem.eql(u8, a, b))
                            break false;
                    } else true,
            };
    }

    pub fn resolve(gpa: std.mem.Allocator, ara: std.mem.Allocator, io: std.Io, addr_str: []const u8, inst: ?ClientInstall, proj: ?Project) !@This() {
        const l = log(.remote_address_resolve);
        if (addr_str.len > 0 and addr_str[0] == '!') {
            const cmd = try parse_cmd(gpa, addr_str[1..]);
            cmd[0] = script: {
                if (proj) |p|
                    if (try p.locate_script(gpa, io, cmd[0])) |path| {
                        defer gpa.free(path);
                        break :script try ara.dupe(u8, path);
                    };
                if (inst) |i|
                    if (try i.locate_script(gpa, io, cmd[0])) |path| {
                        defer gpa.free(path);
                        break :script try ara.dupe(u8, path);
                    };

                l.err("Could not resolve location of script '{s}' from remote address", .{cmd[0]});
                return error.ScriptNotFound;
            };
            return .{ .cmd = cmd };
        } else {
            const host, const port = if (std.mem.lastIndexOfScalar(u8, addr_str, ':')) |colon|
                .{ addr_str[0..colon], try std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) }
            else
                .{ addr_str, 9338 };

            const ip = std.Io.net.IpAddress.parse(
                host,
                port,
            ) catch blk: {
                var results: [16]std.Io.net.HostName.LookupResult = undefined;
                var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&results);
                const host_name: std.Io.net.HostName = try .init(host);
                try host_name.lookup(io, &queue, .{ .port = port });

                break :blk result: while (queue.getOne(io)) |result|
                    switch (result) {
                        .address => |addr| break :result addr,
                        .canonical_name => {},
                    }
                else |err| switch (err) {
                    error.Closed => return error.UnknownHostName,
                    else => |e| return e,
                };
            };
            return .{ .ip = ip };
        }
    }
    pub fn dupe(self: @This(), gpa: std.mem.Allocator) !@This() {
        switch (self) {
            .ip => return self,
            .cmd => |cmd| {
                var list: std.ArrayList([]const u8) = try .initCapacity(gpa, cmd.len);
                defer list.deinit(gpa);
                errdefer for (list.items) |c|
                    gpa.free(c);
                for (cmd) |c|
                    list.appendAssumeCapacity(try gpa.dupe(u8, c));

                return .{ .cmd = try list.toOwnedSlice(gpa) };
            },
        }
    }
    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        switch (self) {
            .cmd => |cmd| {
                for (cmd) |c|
                    gpa.free(c);
                gpa.free(cmd);
            },
            .ip => {},
        }
    }
    fn parse_cmd(gpa: std.mem.Allocator, raw: []const u8) ![][]const u8 {
        const str = std.mem.trim(u8, raw, " \t\r\n");

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |item|
                gpa.free(item);
            list.deinit(gpa);
        }

        var i: usize = 0;
        while (i < str.len) {
            while (i < str.len and (str[i] == ' ' or str[i] == '\t')) : (i += 1) {}
            if (i >= str.len)
                break;

            var token: std.ArrayList(u8) = .empty;
            errdefer token.deinit(gpa);

            while (i < str.len and str[i] != ' ' and str[i] != '\t') {
                if (str[i] == '\'' or str[i] == '"') {
                    const quote = str[i];
                    i += 1;
                    while (i < str.len and str[i] != quote) : (i += 1) {
                        if (str[i] == '\\' and i + 1 < str.len)
                            i += 1;
                        try token.append(gpa, str[i]);
                    }
                    if (i < str.len and str[i] == quote)
                        i += 1;
                } else if (str[i] == '\\' and i + 1 < str.len) {
                    i += 1;
                    try token.append(gpa, str[i]);
                    i += 1;
                } else {
                    try token.append(gpa, str[i]);
                    i += 1;
                }
            }
            try list.append(gpa, try token.toOwnedSlice(gpa));
        }

        return try list.toOwnedSlice(gpa);
    }
};
