const Weft = @import("Weft.zig");
const Lang = @import("script.zig").Lang;
const UUIDv7 = @import("UUIDv7.zig");

pub const Spec = struct {
    service: []const u8,
    workspace: []const u8,
    deployment: UUIDv7,
    env: []const u8,
    pipline: Weft.Pipeline,
    lang: Lang,
};
