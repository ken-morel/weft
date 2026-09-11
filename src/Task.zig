const Weft = @import("Weft.zig");
const UUIDv7 = @import("UUIDv7.zig");

pub const Id = struct {
    workspace: []const u8,
    service: []const u8,
    env: []const u8,
    deployment: UUIDv7,
    pipeline: []const u8,
};

pub const Spec = struct {
    id: Id,
    pipline: Weft.Pipeline,
};
