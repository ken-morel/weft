const std = @import("std");

pub const Workspace = @import("Workspace.zig");
pub const Pipeline = @import("Pipeline.zig");

pub fn keyed(comptime T: type) type {
    return []struct { []const u8, T };
}

name: []const u8 = "service",
workspace: ?[]const u8 = null,

pipelines: ?[]Pipeline = null,

volumes: keyed(Volume),
databases: keyed(Database),
ports: keyed(Port),
runtimes: keyed(Runtime),

required_env: [][]const u8,

env_bindings: keyed(Pipeline.EnvBinding),

pub const Volume = struct {
    max_storage: u64,
    ram_fs: bool,
};

pub const DbConfig = void;

pub const Database = union(enum) {
    postgres: DbConfig,
    redis: DbConfig,
    sqlite: DbConfig,
};

pub const Port = struct {
    port: ?u16,
    domain: ?[]const u8,
};

pub const Runtime = union(enum) {
    rust: struct {
        version: ?[]const u8,
        install: []struct {
            name: []const u8,
            version: ?[]const u8,
            features: []const u8, // coma seprated
        },
    },
    python: struct {
        version: ?[]const u8,
        install: []struct {
            name: []const u8,
            version: []const u8,
        },
    },
    bun: struct {
        version: ?[]const u8,
        install: []struct {
            name: []const u8,
            version: []const u8,
        },
    },
    pacman: struct {
        package: []const u8,
        version: ?[]const u8,
    },
    apt: struct {
        package: []const u8,
        version: ?[]const u8,
    },
    dnf: struct {
        package: []const u8,
        version: ?[]const u8,
    },
};
