const std = @import("std");
const Daemon = @import("../daemon/Daemon.zig");
const Unpacker = @import("../packer.zig").Unpacker;
const Server = @import("../Server.zig");
const UUIDv7 = @import("../UUIDv7.zig");

pub fn handle_artifact_push(self: *Daemon, arena: *std.heap.ArenaAllocator, req: *Server.Request) !void {
    try self.term.printlnf("    artifact push: ", .{});
    const conn = &req.conn;
    const alloc = arena.allocator();

    var msg_arena: std.heap.ArenaAllocator = .init(alloc);
    defer msg_arena.deinit();

    const artifact_id = switch (try conn.recv(arena)) {
        .artifact_id => |art_id| art_id,
        else => return error.SyntaxEror,
    };

    const temp_dir = try self.install.open_temp(self.io, "artifact");
    defer temp_dir.close(self.io);
    const temp_dir_path = try temp_dir.realPathFileAlloc(self.io, ".", alloc);
    defer alloc.free(temp_dir_path);

    const artifact_dir_path = try self.install.get_artifact_dir_path(alloc, artifact_id);
    defer alloc.free(artifact_dir_path);
    try self.term.printlnf("Receiving artifact {s} to: {s}", .{ artifact_dir_path, temp_dir_path });

    {
        var unpacker: *Unpacker = try .init(alloc, temp_dir);
        defer unpacker.destroy(alloc, self.io);

        while (true) {
            switch (try conn.recv(&msg_arena)) {
                .folder => |folder| try unpacker.folder(self.io, folder),
                .file => |file| try unpacker.file(self.io, file),
                .data => |data| try unpacker.chunk(self.io, data),
                .end => break,
                else => return error.SyntaxError,
            }
            _ = msg_arena.reset(.retain_capacity);
        }
    }

    try std.Io.Dir.cwd().rename(temp_dir_path, std.Io.Dir.cwd(), artifact_dir_path, self.io);
    try conn.send(.{ .ok = {} });
}
