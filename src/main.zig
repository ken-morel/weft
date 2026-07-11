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
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const content = try std.Io.Dir.cwd().readFileAlloc(init.io, "Weft", alloc, .unlimited);
    var prs = Parser.create(alloc, content) orelse return error.EmptyFile;
    prs.parse() catch |err| {
        std.debug.print("Weft:{any}:{any} {any}", .{ prs.ln + 1, prs.idx + 1, err });
        try prs.print_trace(init.io);
        return err;
    };
    std.debug.print("{any}", .{prs.conf});
}
