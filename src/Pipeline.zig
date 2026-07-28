const std = @import("std");
pub const NumPattern = @import("numpattern.zig").NumPattern;
pub const Glob = @import("Glob.zig");
pub const Script = @import("Script.zig");
pub const keyed = @import("Service.zig").keyed;
pub const Target = @import("Target.zig");

name: []const u8,
inputs: []Input = &.{},

runtimes: [][]const u8 = &.{},
volumes: [][]const u8 = &.{},
databases: [][]const u8 = &.{},

keep: []Glob = &.{},

second_instance: ?SecondInstance = null,

script: ?Script = null,

required_env: [][]const u8 = &.{},
env_bindings: keyed(EnvBinding) = &.{},

pub const Input = struct {
    target: Target,
    consume: bool,
};

pub const SecondInstance = union(enum) {
    wait: ?u32,
    safe: u32,
    kill,
    ignore,
};

pub const EnvBinding = union(enum) {
    database: []const u8,
    volume: []const u8,
    port: []const u8,
    string: []const u8,
    env_var: []const u8,
    interpolate: []EnvBinding,
};
