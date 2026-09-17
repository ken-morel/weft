const std = @import("std");

const Weft = @import("../domain/Weft.zig");
const UUIDv7 = @import("../util/UUIDv7.zig");

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
        pub fn dupe(self: @This(), alloc: std.mem.Allocator) !@This() {
            const workspace = try alloc.dupe(self.workspace);
            errdefer alloc.free(workspace);
            const service = try alloc.dupe(self.service);
            errdefer alloc.free(service);
            const env = try alloc.dupe(self.env);
            errdefer alloc.free(env);
            const pipeline = try alloc.dupe(self.pipeline);
            errdefer alloc.free(pipeline);
            return .{
                .workspace = workspace,
                .service = service,
                .env = env,
                .deployment = self.deployment,
                .pipeline = pipeline,
            };
        }
        pub fn free_duped(self: @This(), alloc: std.mem.Allocator) void {
            alloc.free(self.workspace);
            alloc.free(self.service);
            alloc.free(self.env);
            alloc.free(self.pipeline);
        }
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
            time: std.Io.Timestamp,
            ram: struct {
                total: u64,
                used: u64,
            },
            zram: struct {
                total: u64,
                used: u64,
                compressed: u64,
            },
            swap: struct {
                total: u64,
                used: u64,
                io: struct { u64, u64 },
            },
            cpu: struct {
                freq: u32,
                usage_percent: u8,
            },
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
