const Weft = @import("Weft.zig");
const UUIDv7 = @import("UUIDv7.zig");

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
    pub const kill = struct {
        pub const Req = struct {
            task: task.Id,
        };
    };
    pub const status = struct {
        pub const Req = struct {
            task: task.Id,
        };
    };
    pub const logs = struct {
        pub const Req = struct {
            task: task.Id,
            stream: bool,
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
};
