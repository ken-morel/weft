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
    const Input = []const u8;
    const Output = []const u8;
    pub const SecondInstance = union(enum) {
        kill: void,
        ignore: void,
        fail: void,
    };
    pub const Run = union(enum) {
        default,
        script: []const u8,
        nothing,
    };

    name: []const u8,
    in: []const Input = &.{},
    out: ?[]const Output = null,
    run: Run = .default,

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

    pub fn inputs(self: @This()) []const []const u8 {
        return self.in;
    }
    pub fn outputs(self: @This()) []const []const u8 {
        return self.out orelse &.{self.name};
    }
};

workspace: []const u8,
sources: ?[]const struct { []const u8, []const u8 } = null,

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
pub fn get_sources(self: @This()) []const struct { []const u8, []const u8 } {
    return if (self.sources) |s|
        s
    else
        &.{.{ "src", "." }};
}

pub fn is_source_artifact(p: []const u8) bool {
    return std.mem.startsWith(u8, p, "src.") or std.mem.eql(u8, p, "src");
}
