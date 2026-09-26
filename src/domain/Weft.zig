const std = @import("std");

const Glob = @import("../util/Glob.zig");

pub const Keep = struct {
    []const u8,
    []const u8,
};

pub const Pipeline = struct {
    const Input = []const u8;
    const Output = []const u8;
    pub const SecondInstance = union(enum) {
        kill: void,
        ignore: void,
        fail: void,
    };
    pub const Run = union(enum) {
        default,
        script: []const []const u8,
        file: []const u8,
        nothing,
    };

    name: []const u8,
    in: []const Input = &.{},
    out: ?[]const Output = null,
    run: Run = .default,

    //TODO
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

    second_instance: SecondInstance = .ignore,
    keep: []Keep = &.{},

    uses: []const []const u8 = &.{},

    pub fn inputs(self: @This()) []const []const u8 {
        return self.in;
    }
    pub fn produces(self: @This(), artifact: []const u8) bool {
        if (self.out) |outs| {
            for (outs) |out| {
                if (std.mem.eql(u8, out, artifact))
                    return true;
            }
            return false;
        }
        return std.mem.eql(u8, self.name, artifact);
    }
    pub fn outputs(self: *const @This(), buf: *[1][]const u8) []const []const u8 {
        if (self.out) |o|
            return o;
        buf[0] = self.name;
        return buf;
    }
};

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
pub inline fn get_sources(self: @This()) []const struct { []const u8, []const u8 } {
    return if (self.sources) |s|
        s
    else
        &.{.{ "", "." }};
}

pub inline fn is_source_artifact(p: []const u8) bool {
    return std.mem.eql(u8, p, "src") or std.mem.startsWith(u8, p, "src.");
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
    vars: []struct { []const u8, ?[]const u8 } = &.{},
    pkgs: []const []const u8 = &.{},
    databases: []const Database = &.{},
    pub const Database = struct {
        name: []const u8,
        type: enum { postgres },
    };
};
