const std = @import("std");
const Glob = @import("Glob.zig");
const script = @import("script.zig");

pub const EnvBinding = union(enum) {
    database: []const u8,
    volume: []const u8,
    port: []const u8,
    string: []const u8,
    env_var: []const u8,
    interpolate: []const EnvBinding,
    pub fn parse(val: []const u8) !@This() {
        _ = val;
        unreachable;
    }
};

pub const Keep = struct {
    name: []const u8,
    path: []const u8,
};
pub const Pipeline = struct {
    const Input = struct {
        name: []const u8,
    };
    const Ouptut = struct {
        name: []const u8,
    };
    const SecondInstance = union(enum) {
        wait: ?u32,
        safe: u32,
        kill: void,
        ignore: void,
    };

    name: []const u8,
    inputs: []const Input = &.{},
    outputs: []const Ouptut = &.{},
    script: []const u8,

    max_ram: ?u64 = null,
    mem_lock: bool = false,

    second_instance: SecondInstance = .ignore,
    keep: []Keep = &.{},

    required_env: []const []const u8 = &.{},

    databases: []const struct {} = &.{},
    volumes: []const struct {} = &.{},
    ports: []const struct {} = &.{},
    runtimes: []const struct {} = &.{},
    env: []struct { []const u8, []const u8 } = &.{},
};

name: []const u8,
workspace: []const u8,

databases: []const struct {} = &.{},
ports: []const struct {} = &.{},
volumes: []const struct {} = &.{},
runtimes: []const struct {} = &.{},
env: []struct { []const u8, []const u8 } = &.{},

pipelines: []const Pipeline = &.{},

pub fn get_pipeline(self: @This(), name: []const u8) ?*const Pipeline {
    for (self.pipelines) |*pipeline|
        if (std.mem.eql(u8, pipeline.name, name))
            return pipeline;
    return null;
}
