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
        script: []const u8,
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
            hosts: []const u8 =
                \\127.0.0.1 localhost localhost.localdomain
                \\::1 localhost localhost.localdomain
                \\
            ,
        };
        const Io = struct {
            io_weight: ?u32 = null,
            pids_max: ?u64 = null,
            mount: []const struct {
                []const u8,
                enum { tmpfs, read, read_write },
                []const u8,
            } = &.{},
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
    pub fn matches_remote(self: @This(), remote: anytype) bool {
        return if (self.on) |on_list|
            for (on_list) |target| {
                if (remote_has_group(remote, target))
                    break true;
            } else false
        else
            true;
    }
};
pub const Remote = struct {
    /// The remote name
    []const u8,
    /// The weft host:port or !script, or null if loaded from client config
    ?[]const u8,
    /// The remote tags seperated by spaces
    []const u8,
};

pub fn remote_has_group(remote: anytype, group: []const u8) bool {
    const raw_groups = if (@hasField(@TypeOf(remote), "groups"))
        remote.groups
    else
        remote.@"2";
    var iter = std.mem.splitScalar(u8, raw_groups, ' ');
    return while (iter.next()) |item| {
        if (item.len > 0 and std.mem.eql(u8, item, group))
            break true;
    } else false;
}

modes: []const []const u8 = &.{"default"},
environments: []const Env = &.{},
workspace: []const u8,
sources: ?[]const struct { []const u8, []const u8 } = null,

pipelines: []const Pipeline = &.{},
remotes: []const Remote = &.{.{ "local", null, "local" }},

retention: Retention = .{},

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
    return null;
}

pub fn select_remote_for(self: @This(), pipeline: *const Pipeline, group: []const u8) ?Remote {
    for (self.remotes) |remote|
        if (remote_has_group(remote, group))
            if (pipeline.matches_remote(remote))
                return remote;
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
    return for (self.modes) |m| {
        if (std.mem.eql(u8, m, mode))
            break true;
    } else false;
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
        for (name[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.')
                break false;
        } else true;
}
