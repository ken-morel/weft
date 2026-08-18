const std = @import("std");
const Daemon = @import("../daemon/Daemon.zig");
const Unpacker = @import("../packer.zig").Unpacker;
const Server = @import("../Server.zig");
const UUIDv7 = @import("../UUIDv7.zig");

fn handle_one_request(self: *Daemon, req: *Server.Request) !?void {
    try self.term.printf("  Accepting client request...", .{});
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const conn = &req.conn;

    const msg = try conn.recv(&arena);
    try self.term.printlnf(":{any}", .{msg});
    switch (msg) {
        .request => |r| switch (r) {
            .artifact_push => try handle_artifact_push(self, &arena, req),
            else => {},
        },
        else => return error.InvalidRequest,
    }
}
fn handle_artifact_push(self: *Daemon, arena: *std.heap.ArenaAllocator, req: *Server.Request) !void {
    try self.term.printlnf("    artifact push: ", .{});
    const conn = &req.conn;
    const alloc = arena.allocator();

    const artifact_id = switch (try conn.recv(arena)) {
        .artifact_id => |art_id| art_id,
        else => return error.SyntaxEror,
    };

    var temp_dir_path: [55]u8 = undefined;
    std.mem.copyForwards(u8, temp_dir_path[0..19], "/tmp/weft/artifacts");
    _ = try (try UUIDv7.now(self.io)).to_string(temp_dir_path[19..]);
    const temp_dir = try std.Io.Dir.cwd().openDir(self.io, &temp_dir_path, .{ .iterate = true });
    defer temp_dir.close(self.io);

    const artifact_dir_path = try self.install.get_artifact_dir_path(alloc, artifact_id);
    defer alloc.free(artifact_dir_path);
    try self.term.printlnf("Receiving artifact {s} to: {s}", .{ artifact_dir_path, temp_dir_path });

    {
        var unpacker: *Unpacker = try .init(alloc, temp_dir);
        defer unpacker.destroy(alloc, self.io);

        while (true) {
            var msg_arena: std.heap.ArenaAllocator = .init(alloc);
            defer msg_arena.deinit();

            switch (try conn.recv(&msg_arena)) {
                .folder => |folder| try unpacker.folder(self.io, folder),
                .file => |file| try unpacker.file(self.io, file),
                .data => |data| try unpacker.chunk(self.io, data),
                .end => break,
                else => return error.SyntaxError,
            }
        }
    }

    try std.Io.Dir.cwd().rename(&temp_dir_path, std.Io.Dir.cwd(), artifact_dir_path, self.io);
    try conn.send(.{ .ok = {} });
}

pub fn handle_conn(self: *Daemon, req: *Server.Request) void {
    defer req.destroy(self.alloc, self.io);
    defer self.term.printlnf("Connection destroyed", .{}) catch {};

    while (true)
        handle_one_request(self, req) catch |err| {
            self.term.err("Error Handling request: {any}", .{err}) catch {};
            break;
        } orelse break;
}
