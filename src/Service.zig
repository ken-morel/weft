const std = @import("std");
pub const Pipeline = @import("Pipeline.zig");

pub fn keyed(comptime T: type) type {
    return []struct { []const u8, T };
}

name: []const u8 = "service",
workspace: []const u8 = "workspace",
pipelines: []Pipeline = &.{},
required_env: [][]const u8 = &.{},
env_bindings: keyed(Pipeline.EnvBinding) = &.{},

pub fn get_pipeline(self: @This(), name: []const u8) ?*const Pipeline {
    for (self.pipelines) |*pipeline|
        if (std.mem.eql(u8, pipeline.name, name))
            return pipeline;
    return null;
}
