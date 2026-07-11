const std = @import("std");
pub const NumPattern = @import("../parser/numpattern.zig").NumPattern;
pub const Glob = @import("../parser/Glob.zig");
pub const Script = @import("Script.zig");

name: []const u8,
inputs: []Input,

runtimes: [][]const u8,
volumes: [][]const u8,
databases: [][]const u8,

keep: []Glob,

second_instance: ?SecondInstance,

script: ?Script = null,

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
