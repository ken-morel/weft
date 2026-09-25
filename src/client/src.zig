const std = @import("std");

const Term = @import("../domain/Term.zig");
const Walker = @import("../util/Walker.zig");
const Connection = @import("../wire/Connection.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const runner = @import("runner.zig");

pub fn create_sources(alloc: std.mem.Allocator, io: std.Io, _: *Term, inst: ClientInstall, project: Project, deployment: *Deployment) !void {
    const sources = deployment.config.get_sources();

    source: for (sources) |source| {
        const source_name = if (source.@"0".len > 0)
            try std.mem.join(alloc, ".", &.{ "src", source.@"0" })
        else
            try alloc.dupe(u8, "src");
        defer alloc.free(source_name);
        const source_dir_path = try project.artifact_dir_path(alloc, io, deployment.id, source_name);
        defer alloc.free(source_dir_path);

        source_exists: {
            std.Io.Dir.cwd().access(io, source_dir_path, .{}) catch |err|
                if (err == error.FileNotFound)
                    break :source_exists
                else
                    return err;
            continue :source;
        }

        const temp_dir = try inst.open_temp(io, "sources");
        defer temp_dir.close(io);

        const temp_dir_path = try temp_dir.realPathFileAlloc(io, ".", alloc);
        defer alloc.free(temp_dir_path);

        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();

        var walk_root = try project.dir.openDir(io, source.@"1", .{ .iterate = true });
        defer walk_root.close(io);
        var walker: Walker = try .init(&arena, io, walk_root);
        defer walker.deinit(&arena);

        while (try walker.next(&arena, io)) |entry|
            switch (entry) {
                .file => |path| try walk_root.copyFile(
                    path,
                    temp_dir,
                    path,
                    io,
                    .{
                        .make_path = true,
                        .replace = true,
                    },
                ),
                .dir => |path| try temp_dir.createDirPath(io, path),
            };

        if (std.fs.path.dirname(source_dir_path)) |parent|
            std.Io.Dir.cwd().createDirPath(io, parent) catch {};

        try std.Io.Dir.cwd().rename(
            temp_dir_path,
            std.Io.Dir.cwd(),
            source_dir_path,
            io,
        );
        try deployment.add_source(alloc, source.@"0");
    }
}
