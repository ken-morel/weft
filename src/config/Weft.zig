const std = @import("std");

pub const Workspace = @import("Workspace.zig");
pub const Pipeline = @import("Pipeline.zig");

pub fn keyed(comptime T: type) type {
    return []struct { []const u8, T };
}

name: ?[]const u8 = null,

volumes: ?keyed([]const u8) = null,
databases: ?keyed([]const u8) = null,
ports: ?keyed([]const u8) = null,

pipelines: ?[]Pipeline = null,
