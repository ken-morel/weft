const std = @import("std");

const Glob = @import("../util/Glob.zig");

pub const EnvBinding = union(enum) {
    database: []const u8,
    volume: []const u8,
    port: []const u8,
    string: []const u8,
    env_var: []const u8,
    interpolate: []const EnvBinding,
};

pub const Keep = struct {
    []const u8,
    []const u8,
};
pub const Pipeline = struct {
    const Input = struct {
        name: []const u8,
    };
    const Output = struct {
        name: []const u8,
    };
    pub const SecondInstance = union(enum) {
        kill: void,
        ignore: void,
        fail: void,
    };

    name: []const u8,
    inputs: []const Input = &.{},
    outputs: []const Output = &.{},
    script: bool = true,

    max_ram: ?u64 = null,
    mem_lock: bool = false,
    disable_network: bool = true,
    oom_score_adjust: ?i32 = null,

    memory_max: ?u64 = null,
    memory_high: ?u64 = null,
    cpu_quota: ?u16 = null,
    tasks_max: ?u32 = null,
    io_weight: ?u32 = null,
    timeout: ?u32 = null,

    second_instance: SecondInstance = .ignore,
    keep: []Keep = &.{},

    required_env: []const []const u8 = &.{},

    databases: []const struct {} = &.{},
    volumes: []const struct {} = &.{},
    ports: []const struct {} = &.{},
    runtimes: []const struct {} = &.{},
    env: []struct { []const u8, []const u8 } = &.{},
};

workspace: []const u8,

databases: []const struct {} = &.{},
ports: []const struct {} = &.{},
volumes: []const struct {} = &.{},
runtimes: []const struct {} = &.{},
env: []struct { []const u8, []const u8 } = &.{},

pipelines: []const Pipeline = &.{},
required_env: []const []const u8 = &.{},

pub fn get_pipeline(self: @This(), name: []const u8) ?*const Pipeline {
    for (self.pipelines) |*pipeline|
        if (std.mem.eql(u8, pipeline.name, name))
            return pipeline;
    return null;
}
