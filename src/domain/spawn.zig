const std = @import("std");

pub fn spawn(io: std.Io, group: *std.Io.Group, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) void {
    group.async(io, struct {
        fn spawn(func_: anytype, args_: std.meta.ArgsTuple(@TypeOf(func_))) std.Io.Cancelable!void {
            @call(.auto, func_, args_) catch |err| {
                if (err == error.Canceled) return err else {
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpErrorReturnTrace(trace);
                    std.debug.print("Task error: {any}", err);
                }
            };
        }
    }.spawn, .{ func, args });
}
