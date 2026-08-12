const std = @import("std");
pub const NumPattern = @import("numpattern.zig").NumPattern;
pub const Glob = @import("Glob.zig");
pub const Script = @import("Script.zig");
pub const keyed = @import("Service.zig").keyed;
pub const Target = @import("Target.zig");
const Deployment = @import("Deployment.zig");

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

pub const Input = union(enum) {
    src: struct {},
    artifact: struct {
        pipeline: []const u8,
        exit_pattern: ?NumPattern(u8),
        consume: bool,
        pub fn could_match(self: @This(), run: Deployment.Running) bool {
            if (!std.mem.eql(u8, self.pipeline, run.pipeline))
                return false;
            return true;
        }
        pub fn matches(self: @This(), artifact: Deployment.Artifact) bool {
            if (!std.mem.eql(u8, self.pipeline, artifact.pipeline))
                return false;
            if (self.exit_pattern) |pattern|
                if (!pattern.matches(artifact.exit_code))
                    return false;
            return true;
        }
    },
    pub fn matches(self: @This(), artifact: Deployment.Artifact) bool {
        return switch (self) {
            .artifact => |a| a.matches(artifact),
            .src => false,
        };
    }
    pub fn could_match(self: @This(), run: Deployment.Running) bool {
        return switch (self) {
            .artifact => |a| a.could_match(run),
            .src => false,
        };
    }
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
