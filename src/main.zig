const std = @import("std");
const NumPattern = @import("parser/numpattern.zig").NumPattern;
const Glob = @import("parser/Glob.zig");
const Parser = @import("parser/Parser.zig");

pub const std_options: std.Options = .{
    .fmt_max_depth = 10,
};

comptime {
    _ = NumPattern;
    _ = Glob;
    _ = Parser;
    _ = @import("parser/VersionSpec.zig");
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    const ws_content = std.Io.Dir.cwd().readFileAlloc(init.io, "Workspace", alloc, .unlimited) catch |err| blk: {
        if (err == error.FileNotFound) break :blk @as([]const u8, "");
        return err;
    };

    if (ws_content.len > 0) {
        var prs = Parser.create(alloc, ws_content) orelse return error.EmptyFile;
        const ws = prs.parse_workspace() catch |err| {
            std.debug.print("Workspace:{any}:{any} {any}", .{ prs.ln + 1, prs.idx + 1, err });
            try prs.print_trace(init.io);
            return err;
        };
        std.debug.print("Workspace:\n{any}\n", .{ws});
    }

    const svc_content = std.Io.Dir.cwd().readFileAlloc(init.io, "Service", alloc, .unlimited) catch |err| blk: {
        if (err == error.FileNotFound) break :blk @as([]const u8, "");
        return err;
    };

    if (svc_content.len > 0) {
        var prs = Parser.create(alloc, svc_content) orelse return error.EmptyFile;
        const svc = prs.parse_service() catch |err| {
            std.debug.print("Service:{any}:{any} {any}", .{ prs.ln + 1, prs.idx + 1, err });
            try prs.print_trace(init.io);
            return err;
        };
        std.debug.print("Service:\n{any}\n", .{svc});
    }
}
