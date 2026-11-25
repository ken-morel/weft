const std = @import("std");
const log = std.log.scoped;

pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    var weft_dir = try std.Io.Dir.cwd().createDirPathOpen(io, "weft", .{});
    defer weft_dir.close(io);

    weft_dir.access(
        io,
        "weft.zon",
        .{},
    ) catch |e| if (e == error.FileNotFound) {
        const cwd_path = try weft_dir.realPathFileAlloc(io, "..", gpa);
        defer gpa.free(cwd_path);

        const basename = std.fs.path.basename(cwd_path);

        const weft_zon = try std.fmt.allocPrint(
            gpa,
            \\.{{
            \\    .workspace = "{s}",
            \\    .remotes = .{{
            \\        .local = .{{ .groups = "local" }},
            \\    }},
            \\    .pipelines = .{{}},
            \\}}
            \\
        ,
            .{basename},
        );
        defer gpa.free(weft_zon);
        try weft_dir.writeFile(io, .{ .sub_path = "weft.zon", .data = weft_zon });
    } else return e;
    weft_dir.access(io, ".gitignore", .{}) catch |e|
        if (e == error.FileNotFound) {
            try weft_dir.writeFile(
                io,
                .{ .sub_path = ".gitignore", .data =
                \\do
                \\cache
                },
            );
        } else return e;

    try weft_dir.createDirPath(io, "do");
    try weft_dir.createDirPath(io, "cache");
}
