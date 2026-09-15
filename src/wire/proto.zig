const std = @import("std");

const UUIDv7 = @import("../util/UUIDv7.zig");
const Weft = @import("../domain/Weft.zig");

pub fn Res(comptime T: type) type {
    return anyerror!T;
}

pub const artifact = struct {
    pub const push = struct {
        pub const folder: u8 = 0xaa;
        pub const file: u8 = 0xbb;
        pub const raw: u8 = 0xcc;
        pub const compressed: u8 = 0xdd;
        pub const end: u8 = 0xee;

        pub const Req = struct {
            id: task.Id,
        };
        pub const Res = struct {};
    };
    pub const pull = struct {
        pub const Req = struct {
            task: task.Id,
        };
    };
    pub const Id = task.Id;
};
pub const task = struct {
    pub const Id = struct {
        workspace: []const u8,
        service: []const u8,
        env: []const u8,
        deployment: UUIDv7,
        pipeline: []const u8,
    };

    pub const spawn = struct {
        pub const data: u8 = 0xba;
        pub const end: u8 = 0xbb;
        pub const Req = struct {
            task: task.Id,
            pipeline: Weft.Pipeline,
        };
        pub const Res = struct {};
    };
};
pub const system = struct {
    pub const stats = struct {
        pub const Stats = struct {
            const MemInfo = struct {
                total: u64,
                free: u64,
                available: ?u64,
                compressed: ?u64,
            };
            const Mem = union(enum) {
                swapfile: MemInfo,
                zram: MemInfo,
                ram: MemInfo,
            };
            time: std.Io.Timestamp,
            mem: []Mem,
        };

        pub const Req = struct {};
        pub const Res = struct {
            stats: Stats,
        };
    };
};

pub const Request = enum(u8) {
    artifact_push,
    artifact_pull,

    task_spawn,
    task_kill,
    task_status,

    task_logs,

    system_stats,
};
