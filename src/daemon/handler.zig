const std = @import("std");
const Daemon = @import("../daemon/Daemon.zig");
const Unpacker = @import("../packer.zig").Unpacker;
const Server = @import("../Server.zig");

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

    const artifact_dir = try self.install.create_artifact_dir(alloc, self.io, artifact_id);
    defer artifact_dir.close(self.io);
    const path = try artifact_dir.realPathFileAlloc(self.io, ".", alloc);
    defer alloc.free(path);
    try self.term.printlnf("Created artifact dir: {s}", .{path});

    {
        var unpacker: *Unpacker = try .init(alloc, artifact_dir);
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
