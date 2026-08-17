const Step = @import("Step.zig");
const UUIDv7 = @import("UUIDv7.zig");

pub const ServiceId = struct {
    workspace: []const u8,
    name: []const u8,
};

pub const TaskId = struct {
    service: ServiceId,
    deployment: UUIDv7,
    pipeline: []const u8,
};

pub const ArtifactId = TaskId;
