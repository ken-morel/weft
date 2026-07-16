const std = @import("std");
const NumPattern = @import("numpattern.zig").NumPattern;
// I'm still working on this part

const Service = @import("Service.zig");
const Workspace = @import("Workspace.zig");

id: u64,

service: Service,
workspace: Workspace,

artifacts: []Artifact = &.{},
running: []Running = &.{},
targets: []Target = &.{},
remotes: []Remote = &.{},

pub const Target = struct {
    remote: []const u8,
    pipeline: []const u8,
    exit_code: NumPattern(u8),
};

pub const Running = struct {
    remote: []const u8,
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
