const std = @import("std");

const Glob = @import("../util/Glob.zig");

pub const Keep = struct {
    []const u8,
    []const u8,
};

pub const Retention = struct {
    artifacts: u32 = 2,
    archive: u32 = 10,
};

pub const Pipeline = struct {
    const Input = []const u8;
    const Output = []const u8;
    pub const HandleSibling = struct {
        then: union(enum) {
            kill,
            ignore,
            fail,
            skip,
        },
        wait: u32 = 0,
        poll: u32 = 5,
    };
    pub const Run = union(enum) {
        script: []const []const u8,
        file: []const u8,
        nothing,
    };
    pub const Tune = struct {
        const Cpu = struct {
            max: ?u64 = null,
            quota: ?u64 = null,
        };
        const Mem = struct {
            max: ?u64 = null,
            high: ?u64 = null,
            oom_score_adjust: ?i32 = null,
            swap: Swap = .{},
            const Swap = struct {
                max: ?u64 = null,
            };
        };
        const Net = struct {
            private: bool = false,
        };
        const Io = struct {
            io_weight: ?u32 = null,
            pids_max: ?u64 = null,
        };
        cpu: Cpu = .{},
        mem: Mem = .{},
        net: Net = .{},
        io: Io = .{},
    };

    name: []const u8,
    in: []const Input = &.{},
    out: ?[]const Output = null,
    run: ?Run = null,
    tune: Tune = .{},
    timeout: ?u32 = null,
    max_retries: u16 = 10,
    retention: ?Retention = null,

    sibling: HandleSibling = .{ .then = .ignore },
    keep: []Keep = &.{},
    on: ?[]const []const u8 = null,

    env: struct {
        uses: []const []const u8 = &.{},
        vars: []const struct { []const u8, ?[]const u8 } = &.{},
        pkgs: []const []const u8 = &.{},
    } = .{},

    pub fn environ(self: @This()) Env {
        return .{
            .uses = self.env.uses,
            .vars = self.env.vars,
            .pkgs = self.env.pkgs,
            .name = self.name,
        };
    }
    pub fn produces(self: @This(), artifact: []const u8) bool {
        return if (self.out) |outs|
            for (outs) |out| {
                if (std.mem.eql(u8, out, artifact))
                    return true;
            } else false
        else
            std.mem.eql(u8, self.name, artifact);
    }
    pub fn matches_remote(self: @This(), remote: Remote) bool {
        return if (self.on) |on_list|
            for (on_list) |target| {
                if (remote_matches(remote, target))
                    break true;
            } else false
        else
            true;
    }
};
pub const Remote = struct {
    /// The remote name
    []const u8,
    /// The weft host:port
    []const u8,
    /// The remote tags seperated by spaces
    []const u8,
};
pub const remote_local: Remote = .{ "local", "127.0.0.1:9338", "local" };

pub fn remote_has_group(remote: Remote, group: []const u8) bool {
    var iter = std.mem.splitScalar(u8, remote.@"2", ' ');
    return while (iter.next()) |item| {
        if (item.len > 0 and std.mem.eql(u8, item, group))
            break true;
    } else false;
}

pub fn remote_matches(remote: Remote, name_or_group: []const u8) bool {
    return if (std.mem.eql(u8, remote.@"0", name_or_group))
        true
    else
        remote_has_group(remote, name_or_group);
}

pub fn remotes_with_local_leaky(self: @This(), ara: std.mem.Allocator) ![]const Remote {
    for (self.remotes) |r|
        if (std.mem.eql(u8, r.@"0", "local"))
            return self.remotes;
    const new_remotes = try ara.alloc(Remote, self.remotes.len + 1);

    @memcpy(new_remotes[0..self.remotes.len], self.remotes);
    new_remotes[self.remotes.len] = remote_local;
    return new_remotes;
}

modes: []const []const u8 = &.{"default"},
environments: []const Env = &.{},
workspace: []const u8,
sources: ?[]const struct { []const u8, []const u8 } = null,

pipelines: []const Pipeline = &.{},
remotes: []const Remote = &.{},

retention: Retention = .{},

pub const RemoteAddress = union(enum) {
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

    pub fn parse(gpa: std.mem.Allocator, io: std.Io, addr_str: []const u8) !RemoteAddress {
        if (addr_str.len > 0 and addr_str[0] == '!') {
            const cmd = try parse_cmd(gpa, addr_str);
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
    fn parse_cmd(gpa: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
        var str = raw;
        if (str.len > 0 and str[0] == '!')
            str = str[1..];
        str = std.mem.trim(u8, str, " \t\r\n");

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

pub fn get_pipeline(self: @This(), name: []const u8) ?*const Pipeline {
    return for (self.pipelines) |*pipeline| {
        if (std.mem.eql(u8, pipeline.name, name))
            break pipeline;
    } else null;
}

pub fn find_remote(self: @This(), name: []const u8) ?Remote {
    for (self.remotes) |r|
        if (std.mem.eql(u8, r.@"0", name))
            return r;
    if (std.mem.eql(u8, name, "local"))
        return remote_local;
    return null;
}

pub fn select_remote_for(self: @This(), pipeline: *const Pipeline, preferred_remote_name: ?[]const u8) ?[]const u8 {
    if (preferred_remote_name) |pref_name|
        if (self.find_remote(pref_name)) |pref|
            if (pipeline.matches_remote(pref))
                return pref_name;

    const on_list = pipeline.on orelse return preferred_remote_name orelse "local";

    for (on_list) |target| {
        if (self.find_remote(target)) |r|
            return r.@"0";

        for (self.remotes) |r|
            if (remote_has_group(r, target))
                return r.@"0";

        if (remote_has_group(remote_local, target))
            return "local";
    }

    return null;
}

pub fn get_producer(self: @This(), output: []const u8) ?*const Pipeline {
    return pipeline: for (self.pipelines) |*pipeline| {
        for (pipeline.out orelse &.{pipeline.name}) |out|
            if (std.mem.eql(u8, out, output))
                break :pipeline pipeline;
    } else null;
}
pub inline fn get_sources(self: @This()) []const struct { []const u8, []const u8 } {
    return if (self.sources) |s|
        s
    else
        &.{.{ "", "." }};
}

pub inline fn is_source_artifact(p: []const u8) bool {
    return p.len > 0 and p[0] == '-';
}

pub fn get_environment(self: @This(), name: []const u8) ?*const Env {
    return for (self.environments) |*environment| {
        if (std.mem.eql(u8, environment.name, name))
            break environment;
    } else null;
}

pub const Env = struct {
    name: []const u8,
    uses: []const []const u8 = &.{},
    vars: []const struct { []const u8, ?[]const u8 } = &.{},
    pkgs: []const []const u8 = &.{},
};
pub fn has_mode(self: @This(), mode: []const u8) bool {
    return for (self.modes) |m|
        if (std.mem.eql(u8, m, mode))
            break true
        else {}
    else
        false;
}

pub fn strip_mode(mode: ?[]const u8, name: []const u8) ?[]const u8 {
    return if (std.mem.findScalar(u8, name, ':')) |sep|
        if (mode != null and !std.mem.eql(u8, mode orelse unreachable, name[0..sep]))
            null
        else if (sep == name.len - 1)
            name[0..sep]
        else
            name[sep + 1 ..]
    else
        name;
}

pub fn is_valid_artifact_name(name: []const u8) bool {
    return name.len > 0 and
        (std.ascii.isAlphanumeric(name[0]) or name[0] == '-') and
        for (name[1..]) |c|
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.')
                break false
            else {}
        else
            true;
}
