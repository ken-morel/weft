const std = @import("std");
const NumPattern = @import("../parser/numpattern.zig").NumPattern;

id: u64,
workspace: []const u8,
service: []const u8,
artifacts: []Artifact = &.{},
targets: []Target = &.{},
remotes: []Remote = &.{},

pub const Target = struct {
    remote: []const u8,
    pipeline: []const u8,
    exit_code: NumPattern(u8),
};

pub const Artifact = struct {
    remote: []const u8,
    pipeline: []const u8,
    size: u64,
    exit_code: u8,
};

pub const Remote = struct {
    name: []const u8,
    host: []const u8,
    port: u16,
    auth_token: []const u8,
};
