const std = @import("std");

const Glob = @import("../util/Glob.zig");

pub const no_run_script =
    \\ #!/usr/bin/sh
    \\ echo 'Doing nothing'
;
pub const Keep = struct {
    []const u8,
    []const u8,
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
        max_ram: ?u64 = null,
        mem_lock: bool = false,
        disable_network: bool = false,
        oom_score_adjust: ?i32 = null,

        memory_max: ?u64 = null,
        memory_high: ?u64 = null,
        cpu_quota: ?u16 = null,
        tasks_max: ?u32 = null,
        io_weight: ?u32 = null,
        timeout: ?u32 = null,
    };

    name: []const u8,
    in: []const Input = &.{},
    out: ?[]const Output = null,
    run: ?Run,
    tune: Tune = .{},

    sibling: HandleSibling = .{ .then = .ignore },
    keep: []Keep = &.{},

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
};

modes: []const []const u8 = &.{"default"},
environments: []const Env = &.{},
workspace: []const u8,
sources: ?[]const struct { []const u8, []const u8 } = null,

pipelines: []const Pipeline = &.{},

pub fn get_pipeline(self: @This(), name: []const u8) ?*const Pipeline {
    return for (self.pipelines) |*pipeline| {
        if (std.mem.eql(u8, pipeline.name, name))
            break pipeline;
    } else null;
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
        if (mode != null and !std.mem.eql(u8, mode.?, name[0..sep]))
            null
        else if (sep == name.len - 1)
            name[0..sep]
        else
            name[sep + 1 ..]
    else
        name;
}
