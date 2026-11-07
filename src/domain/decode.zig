const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const Task = @import("../daemon/Task.zig");
const proto = @import("../domain/proto.zig");
const Weft = @import("../domain/Weft.zig");
const Monitor = @import("../util/Monitor.zig");
const zoto = @import("../util/zoto.zig");

pub const types = [_]type{
    Task.Status,
    Task.Spec,
    Task,
    proto.task.Id,

    Deployment,
    Weft,
    Monitor.Stats,

    proto.Request,
    proto.DaemonMsg,

    proto.artifact.push.Req,
    proto.artifact.push.Res,
    proto.Res(proto.artifact.push.Res),

    proto.artifact.pull.Req,
    proto.artifact.pull.Res,
    proto.Res(proto.artifact.pull.Res),

    proto.artifact.has.Req,
    proto.artifact.has.Res,
    proto.Res(proto.artifact.has.Res),

    proto.task.spawn.Req,
    proto.task.spawn.Res,
    proto.Res(proto.task.spawn.Res),

    proto.task.poll.Req,
    proto.task.poll.Res,
    proto.Res(proto.task.poll.Res),

    proto.task.kill.Req,
    proto.task.kill.Res,
    proto.Res(proto.task.kill.Res),

    proto.system.stats.Req,

    proto.Pack,
};

pub fn decode_and_print(
    gpa: std.mem.Allocator,
    raw: []const u8,
    out: *std.Io.Writer,
) !void {
    var data = raw;
    if (std.mem.startsWith(u8, data, "ZOTO"))
        data = data[4..];

    if (data.len < @sizeOf(u64))
        return error.BufferTooSmall;

    const hash = std.mem.readInt(u64, data[0..@sizeOf(u64)], .little);
    const payload = data[@sizeOf(u64)..];

    inline for (types) |T| {
        if (hash == comptime zoto.hashType(T)) {
            var parse_slice = payload;
            const val = try zoto.deserialize(gpa, &parse_slice, T, .{
                .header = false,
                .hash = false,
            });

            try out.writeAll(@typeName(T));
            try zoto.print_value(T, val, out, 0, true);
            try out.writeByte(';');
            if (parse_slice.len > 0)
                try out.print(" # {d} bytes remaining", .{parse_slice.len});
            try out.writeByte('\n');
            return;
        }
    }

    return error.UnknownTypeHash;
}
