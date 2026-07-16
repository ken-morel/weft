const std = @import("std");
pub const Pipeline = @import("Pipeline.zig");

pub fn keyed(comptime T: type) type {
    return []struct { []const u8, T };
}

name: []const u8 = "service",
workspace: ?[]const u8 = null,
pipelines: []Pipeline = &.{},
required_env: [][]const u8 = &.{},
env_bindings: keyed(Pipeline.EnvBinding) = &.{},
