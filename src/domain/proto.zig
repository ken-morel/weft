const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const Task = @import("../domain/Task.zig");
const Weft = @import("../domain/Weft.zig");
const zoto = @import("../util/zoto.zig");

pub fn R(comptime T: type) type {
    return anyerror!T;
}

pub const Pack = union(enum(u8)) {
    pub const Pull = extern struct {
        can_decompress: bool,
    };
    pub const Push = extern struct {
        compress: bool,
        total_files: u64,
    };
    const hash = zoto.hashType(@This());
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
        pub const Req = struct { id: Task.Id };
        pub const Res = struct {};
        pub const hash = zoto.hashType(struct { Req, Res });
    };
    pub const has = struct {
        pub const Req = struct {
            id: Task.Id,
        };
        pub const Res = struct {
            has: bool,
        };
        pub const hash = zoto.hashType(struct { Req, Res });
    };
    pub const pull = struct {
        pub const Req = struct {
            id: Task.Id,
        };
        pub const Res = struct {};
        const hash = zoto.hashType(struct { Req, Res });
    };
};
pub const cache = struct {
    pub const Id = struct {
        workspace: []const u8,
        name: []const u8,
    };
    pub const push = struct {
        pub const Req = struct { id: Id };
        pub const Res = struct {};
        const hash = zoto.hashType(struct { Req, Res });
    };
    pub const pull = struct {
        pub const Req = struct { id: Id };
        pub const Res = struct {};
        const hash = zoto.hashType(struct { Req, Res });
    };
    pub const has = struct {
        pub const Req = struct { id: Id };
        pub const Res = struct {
            has: bool,
        };
        const hash = zoto.hashType(struct { Req, Res });
    };
};
pub const task = struct {
    pub const spawn = struct {
        pub const Req = struct {
            spec: Task.Spec,
        };
        pub const Res = struct {};
        const hash = zoto.hashType(struct { Req, Res });
    };
    pub const poll = struct {
        pub const Status = ?Task.Status;
        pub const Logs = struct {
            data: []const u8,
            end_offset: u64,
            more: usize,
        };
        pub const TaskUsage = struct {
            cpu_usec: u64 = 0,
            memory_bytes: u64 = 0,
        };
        pub const Req = ?struct {
            task: Task.Id,
            logs_offset: ?u64,
        };
        pub const Res = ?struct {
            task: Task.Id,
            logs: ?Logs,
            status: Status,
            usage: ?TaskUsage = null,
        };
        const hash = zoto.hashType(struct { Req, Res });
    };
    pub const kill = struct {
        pub const Req = struct {
            workspace: []const u8 = "",
            deployment: Deployment.Id,
            pipeline: []const u8,
        };
        pub const Res = struct {};
        const hash = zoto.hashType(struct { Req, Res });
    };
};

pub const system = struct {
    pub const stats = struct {
        pub const Req = struct {
            from: std.Io.Timestamp,
        };
        const hash = zoto.hashType(struct { Req, void });
    };
};

pub const Request = enum(RR) {
    const RT = u4; // request type
    const RH = u64; // request schema hash
    const RR = @Int(.unsigned, @bitSizeOf(RT) + @bitSizeOf(RH));

    pub const Type = enum(RT) {
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
        _,
    };

    // request

    fn z(comptime h: u64, comptime v: Type) RR {
        return (@as(RR, @truncate(h)) << @bitSizeOf(RT)) + @backingInt(v);
    }

    artifact_push = z(artifact.push.hash, .artifact_push),
    artifact_pull = z(artifact.pull.hash, .artifact_pull),
    artifact_has = z(artifact.has.hash, .artifact_has),

    cache_push = z(cache.push.hash, .cache_push),
    cache_pull = z(cache.pull.hash, .cache_pull),
    cache_has = z(cache.has.hash, .cache_has),

    task_spawn = z(task.spawn.hash, .task_spawn),
    task_poll = z(task.poll.hash, .task_poll),
    task_kill = z(task.kill.hash, .task_kill),

    system_stats = z(system.stats.hash, .system_stats),
    _,

    pub fn hash(self: @This()) RH {
        return @truncate(@backingInt(self) >> @bitSizeOf(RT));
    }
    pub fn req(self: @This()) Type {
        return @fromBackingInt(@as(RT, @truncate(@backingInt(self))));
    }
};

pub const DaemonMsg = union(enum) {
    reload,

    const hash = zoto.hashType(@This());
};
