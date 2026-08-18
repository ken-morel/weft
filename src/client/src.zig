const std = @import("std");
const ClientInstall = @import("../ClientInstall.zig");
const Connection = @import("../Connection.zig");
const Client = @import("../Client.zig");
const Deployment = @import("../Deployment.zig");
const Project = @import("../Project.zig");
const Term = @import("../Term.zig");

const UUIDv7 = @import("../UUIDv7.zig");
const runner = @import("runner.zig");
const Walker = @import("../Walker.zig");

pub fn create_src_artifact(alloc: std.mem.Allocator, io: std.Io, term: *Term, inst: ClientInstall, project: Project, deployment_id: UUIDv7) !void {
    try term.printlnf("Snapshoting src artifact", .{});
    const artifact_dir_path = try project.artifact_dir_path(alloc, io, deployment_id, "src");
    defer alloc.free(artifact_dir_path);

    const temp_dir = try inst.open_temp(io, "src-artifacts");
    defer temp_dir.close(io);
    const temp_dir_path = try temp_dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(temp_dir_path);

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    var walk_root = try project.dir.openDir(io, ".", .{ .iterate = true });
    defer walk_root.close(io);
    var walker: Walker = try .init(&arena, io, walk_root);
    defer walker.deinit(&arena);

    try walker.ignore_list.append(arena.allocator(), .parse(".weft", null));

    while (try walker.next(&arena, io)) |entry|
        switch (entry) {
            .file => |path| try project.dir.copyFile(
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

    if (std.fs.path.dirname(artifact_dir_path)) |parent|
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};

    try std.Io.Dir.cwd().rename(
        temp_dir_path,
        std.Io.Dir.cwd(),
        artifact_dir_path,
        io,
    );
    try term.printlnf("Done", .{});
}
