const std = @import("std");
const keyed = @import("Weft.zig").keyed;

name: []const u8,

volumes: keyed(Volume),
databases: keyed(Database),
ports: keyed(Port),

pub const Volume = struct {
    max_storage: u64,
    ram_fs: bool,
};

pub const DbConfig = struct {
    version: []const u8,
    persist: bool,
};

pub const Database = union(enum) {
    postgres: DbConfig,
    redis: DbConfig,
    sqlite: DbConfig,
};

pub const Port = struct {
    port: ?u16,
    domain: ?[]const u8,
};
