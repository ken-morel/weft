const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const Task = @import("../daemon/Task.zig");
const Weft = @import("../domain/Weft.zig");
const zoto = @import("../util/zoto.zig");

pub fn Res(comptime T: type) type {
    return anyerror!T;
}

pub const Pack = union(enum(u8)) {
    pub const Pull = extern struct {
        allow_compress: bool,
    };
    pub const Push = extern struct {
        total_files: u64,
    };
    pull: Pull,
    push: Push,
    folder,
    file,
    data,
    compressed_data,
    end,
};
pub const header: u8 = 0x7a;

pub const file: u8 = 0xaa;
pub const folder: u8 = 0xab;
pub const end: u8 = 0xff;
pub const data: u8 = 0xea;
pub const compressed_data: u8 = 0xeb;

pub const artifact = struct {
    pub const push = struct {
        pub const Req = struct { id: task.Id };
        pub const Res = struct {};
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
        pub const Req = struct {
            id: task.Id,
        };
        pub const Res = struct {};
    };
    pub const Id = task.Id;
};
pub const cache = struct {
    pub const Id = struct {
        workspace: []const u8,
        name: []const u8,
    };
    pub const push = struct {
        pub const Req = struct { id: Id };
        pub const Res = struct {};
    };
    pub const pull = struct {
        pub const Req = struct { id: Id };
        pub const Res = struct {};
    };
    pub const has = struct {
        pub const Req = struct { id: Id };
        pub const Res = struct {
            has: bool,
        };
    };
};
pub const task = struct {
    pub const Id = struct {
        workspace: []const u8,
        deployment: Deployment.Id,
        pipeline: []const u8,
        pub fn dupe(self: @This(), alloc: std.mem.Allocator) !@This() {
            const workspace = try alloc.dupe(u8, self.workspace);
            errdefer alloc.free(workspace);
            const pipeline = try alloc.dupe(u8, self.pipeline);
            errdefer alloc.free(pipeline);
            return .{
                .workspace = workspace,
                .deployment = self.deployment,
                .pipeline = pipeline,
            };
        }
        pub fn free_duped(self: @This(), alloc: std.mem.Allocator) void {
            alloc.free(self.workspace);
            alloc.free(self.pipeline);
        }
        pub inline fn w(self: @This()) struct { []const u8 } {
            return .{self.workspace};
        }
        pub inline fn w_(self: @This(), a: []const u8) struct { []const u8, []const u8 } {
            return .{ self.workspace, a };
        }
        pub inline fn wp(self: @This()) struct { []const u8, []const u8 } {
            return .{ self.workspace, self.pipeline };
        }
        pub inline fn wpd(self: @This()) struct { []const u8, []const u8, Deployment.Id } {
            return .{ self.workspace, self.pipeline, self.deployment };
        }
        pub inline fn wpd_(self: @This(), a: []const u8) struct { []const u8, []const u8, Deployment.Id, []const u8 } {
            return .{ self.workspace, self.pipeline, self.deployment, a };
        }
        pub inline fn w_d(self: @This(), a: []const u8) struct { []const u8, []const u8, Deployment.Id } {
            return .{ self.workspace, a, self.deployment };
        }
    };

    pub const spawn = struct {
        pub const Req = struct {
            spec: Task.Spec,
        };
        pub const Res = struct {};
    };
    pub const poll = struct {
        pub const Status = ?Task.Status;
        pub const Logs = struct {
            data: []const u8,
            end_offset: u64,
        };
        pub const TaskUsage = struct {
            cpu_usec: u64 = 0,
            memory_bytes: u64 = 0,
        };
        pub const Req = ?struct {
            task: Id,
            logs_offset: ?u64,
        };
        pub const Res = ?struct {
            task: Id,
            logs: ?Logs,
            status: Status,
            usage: ?TaskUsage = null,
        };
    };
    pub const kill = struct {
        pub const Req = struct {
            workspace: []const u8 = "",
            deployment: Deployment.Id,
            pipeline: []const u8,
        };
        pub const Res = struct {};
    };
};

pub const system = struct {
    pub const stats = struct {
        pub const Req = struct {
            from: std.Io.Timestamp,
        };
    };
};

pub const Request = enum(u8) {
    artifact_push,
    artifact_pull,
    artifact_has,

    cache_push,
    cache_pull,
    cache_has,

    task_spawn,
    task_poll,
    task_kill,

    system_stats,
};

pub const DaemonMsg = union(enum) {
    reload_keys,
};

req: Request,
daemon: DaemonMsg,
push_req: artifact.push.Req,
push_res: artifact.push.Res,
pull_req: artifact.pull.Req,
pull_res: artifact.pull.Res,
has_req: artifact.has.Req,
has_res: artifact.has.Res,
cache_push_req: cache.push.Req,
cache_push_res: cache.push.Res,
cache_pull_req: cache.pull.Req,
cache_pull_res: cache.pull.Res,
cache_has_req: cache.has.Req,
cache_has_res: cache.has.Res,
spawn_req: task.spawn.Req,
spawn_res: task.spawn.Res,
poll_req: task.poll.Req,
poll_res: task.poll.Res,
kill_req: task.kill.Req,
kill_res: task.kill.Res,
stats_req: system.stats.Req,
pack: Pack,

pub const hash = zoto.hashType(@This());
