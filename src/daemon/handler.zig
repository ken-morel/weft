const std = @import("std");
const Daemon = @import("../daemon/Daemon.zig");
const Unpacker = @import("../packer.zig").Unpacker;
const Server = @import("../Server.zig");
const UUIDv7 = @import("../UUIDv7.zig");

const artifact_push = @import("artifact_push.zig");

fn handle_one_request(self: *Daemon, req: *Server.Request) !?void {
    try self.term.printf("  Accepting client request...", .{});
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const conn = &req.conn;

    const msg = try conn.recv(&arena);
    try self.term.printlnf(":{any}", .{msg});
    switch (msg) {
        .request => |r| switch (r) {
            .artifact_push => try artifact_push.handle_artifact_push(self, &arena, req),
            else => {},
        },
        else => return error.InvalidRequest,
    }
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
