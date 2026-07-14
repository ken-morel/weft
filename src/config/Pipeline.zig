const std = @import("std");
pub const NumPattern = @import("../parser/numpattern.zig").NumPattern;
pub const Glob = @import("../parser/Glob.zig");
pub const Script = @import("Script.zig");
pub const keyed = @import("Weft.zig").keyed;

name: []const u8,
inputs: []Input,

runtimes: [][]const u8,
volumes: [][]const u8,
databases: [][]const u8,

keep: []Glob,

second_instance: ?SecondInstance,

script: ?Script = null,

required_env: [][]const u8,

env_bindings: keyed(EnvBinding),

pub const Input = struct {
    namespace: ?[]const u8,
    name: []const u8,
    consume: bool,
    code: ?NumPattern(u8),
    same_remote: bool,
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
