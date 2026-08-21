const std = @import("std");
const Daemon = @import("../daemon/Daemon.zig");
const Unpacker = @import("../packer.zig").Unpacker;
const Server = @import("../Server.zig");
const UUIDv7 = @import("../UUIDv7.zig");

// tasks
// $IN ->  dir with / symlinks

// setup build env:
// - setup input artifacts as readonly.
// - $IN to /var/lib/weft/artifacts/{w}/{s}/{e}/{d} ($IN/pipeline gives artifact)
// - $OUT to ~/weft/
// - cwd to ~/

pub fn handle(self: *Daemon, arena: *std.heap.ArenaAllocator, req: *Server.Request) !void {
    try self.term.printlnf("  task spawn", .{});
    const conn = &req.conn;
    const alloc = arena.allocator();

    var msg_arena: std.heap.ArenaAllocator = .init(alloc);
    defer msg_arena.deinit();

    const task_spec = switch (try conn.recv(arena)) {
        .task_spec => |spec| spec,
        else => return error.SyntaxEror,
    };
}
