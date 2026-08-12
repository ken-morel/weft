const std = @import("std");

pub fn keyed(comptime T: type) type {
    return []struct { []const u8, T };
}

name: []const u8 = "workspace",
volumes: ?keyed(Volume) = null,
databases: ?keyed(Database) = null,
ports: ?keyed(Port) = null,
runtimes: ?keyed(Runtime) = null,

pub const Volume = struct {
    max_storage: ?u64,
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

pub const InstallerEntry = struct {
    installer: []const u8,
    version: ?[]const u8 = null,
    package: ?[]const u8 = null,
    features: [][]const u8 = &.{},
};

pub const Runtime = struct {
    primary: InstallerEntry,
    fallbacks: []InstallerEntry = &.{},
};
