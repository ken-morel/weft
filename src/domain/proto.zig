const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const Weft = @import("../domain/Weft.zig");

pub fn Res(comptime T: type) type {
    return anyerror!T;
}

pub const artifact = struct {
    pub const push = struct {
        pub const Req = union(enum) {
            header: struct { id: task.Id },
            folder: []const u8,
            file: []const u8,
            data: []const u8,
            compressed: []const u8,
            end,
        };
        pub const Res = union(enum) {
            has_artifact: bool,
            footer: struct {},
        };
    };
    pub const has = struct {
        pub const Req = struct {
            id: task.Id,
        };
        pub const Res = struct {
            has: bool,
        };
    };
    pub const pull = struct {
        pub const Req = union(enum) {
            header: struct {
                id: task.Id,
            },
        };
        pub const Res = union(enum) {
            files: u32,
            folder: []const u8,
            file: []const u8,
            raw: []const u8,
            compressed: []const u8,
            end,
            footer: struct {},
        };
    };
    pub const Id = task.Id;
};
pub const task = struct {
    pub const Id = struct {
        workspace: []const u8,
        service: []const u8,
        env: []const u8,
        deployment: Deployment.Id,
        pipeline: []const u8,
        pub fn dupe(self: @This(), alloc: std.mem.Allocator) !@This() {
            const workspace = try alloc.dupe(u8, self.workspace);
            errdefer alloc.free(workspace);
            const service = try alloc.dupe(u8, self.service);
            errdefer alloc.free(service);
            const env = try alloc.dupe(u8, self.env);
            errdefer alloc.free(env);
            const pipeline = try alloc.dupe(u8, self.pipeline);
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
    pub const poll = struct {
        pub const Req = union(enum) {
            header: struct {
                task: Id,
                logs_offset: ?u64,
            },
        };
        pub const Logs = struct {
            data: []const u8,
            compressed: bool,
            end_offset: u64,
        };
        pub const Status = union(enum) {
            running,
            success,
            failed: u16,
            not_found,
        };
        pub const Res = union(enum) {
            footer: struct {
                logs: ?Logs,
                status: Status,
            },
        };
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
    artifact_has,

    task_spawn,
    task_poll,

    system_stats,
};

pub const DaemonMsg = union(enum) {
    const TaskCompleted = struct {
        status: u16,
        task: task.Id,
    };
    task_completed: TaskCompleted,
};
