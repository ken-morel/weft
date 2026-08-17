const std = @import("std");
const Glob = @import("Glob.zig");

pub const EnvBinding = union(enum) {
    database: []const u8,
    volume: []const u8,
    port: []const u8,
    string: []const u8,
    env_var: []const u8,
    interpolate: []const EnvBinding,
};

pub const Pipeline = struct {
    const Input = struct {
        name: []const u8,
        env: ?[]const u8 = null,
        readonly: bool = true,
    };
    const Ouptut = struct {
        name: []const u8,
        env: ?[]const u8 = null,
    };
    const SecondInstance = union(enum) {
        wait: ?u32,
        safe: u32,
        kill: void,
        ignore: void,
    };

    name: []const u8,
    inputs: []const Input = &.{},
    output: []const Ouptut,
    script: []const u8,

    second_instance: SecondInstance = .ignore,
    keep: []const Glob = &.{},
    required_env: []const []const u8,

    databases: []const struct {} = &.{},
    volumes: []const struct {} = &.{},
    ports: []const struct {} = &.{},
    runtimes: []const struct {} = &.{},
    env: []const EnvBinding,
};

name: []const u8,
workspace: []const u8,

databases: []const struct {} = &.{},
ports: []const struct {} = &.{},
volumes: []const struct {} = &.{},
runtimes: []const struct {} = &.{},
env: []const EnvBinding,

pipelines: []const Pipeline,

pub fn get_pipeline(self: @This(), name: []const u8) ?*const Pipeline {
    for (self.pipelines) |*pipeline|
        if (std.mem.eql(u8, pipeline.name, name))
            return pipeline;
    return null;
}
