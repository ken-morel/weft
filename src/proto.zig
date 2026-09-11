const Task = @import("Task.zig");
const Weft = @import("Weft.zig");
const UUIDv7 = @import("UUIDv7.zig");

const artifact = struct {
    const Push = struct {
        task: Task.Id,
    };
    const Pull = struct {
        task: Task.Id,
    };
};
const task = struct {
    const Id = struct {
        workspace: []const u8,
        service: []const u8,
        env: []const u8,
        deployment: UUIDv7,
        pipeline: []const u8,
    };

    const Spawn = struct {
        task: Task.Id,
        pipeline: Weft.Pipeline,
    };
    const Kill = struct {
        Task.Id,
    };
};

pub const Request = union(enum(u8)) {
    artifact_push: artifact.Push,
    artifact_pull: artifact.Pull,

    task_spawn: TaskSpawn,
    task_abort: Task.Id,
    task_status: Task.Id,

    task_logs_snapshot: Task.Id,

    task_logs_stream: Task.Id,
};
