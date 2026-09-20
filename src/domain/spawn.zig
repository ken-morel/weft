const std = @import("std");

pub fn spawn(io: std.Io, group: *std.Io.Group, comptime func: anytype, args: anytype) void {
    const S = struct {
        fn runner(a: @TypeOf(args)) std.Io.Cancelable!void {
            @call(.auto, func, a) catch |err|
                if (err == error.Canceled)
                    return error.Canceled
                else {
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    std.debug.print("Task error: {any}\n", .{err});
                };
        }
    };
    group.async(io, S.runner, .{args});
}
