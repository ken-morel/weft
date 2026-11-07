const std = @import("std");

const domain = @import("../domain/domain.zig");
const paths = @import("../domain/paths.zig");

name: []const u8,

pub fn uid(self: @This(), gpa: std.mem.Allocator, io: std.Io) !u32 {
    const cwd: std.Io.Dir = .cwd();

    const lock = lock: {
        break :lock cwd.openFile(io, paths.weft_workspace_uid, .{
            .lock = .exclusive,
            .mode = .read_write,
        }) catch |err|
            if (err == error.FileNotFound)
                break :lock try cwd.createFile(io, paths.weft_workspace_uid, .{
                    .lock = .exclusive,
                    .read = true,
                })
            else
                return err;
    };
    defer lock.close(io);

    const uid_path = try gpa.print(paths.workspace_uid, .{self.name});
    defer gpa.free(uid_path);

    var uid_buf: [32]u8 = undefined;
    if (cwd.readFile(io, uid_path, &uid_buf)) |txt| {
        return try std.fmt.parseInt(
            u32,
            std.mem.trim(u8, txt, " \n\r"),
            10,
        );
    } else |e| if (e == error.FileNotFound) {
        var next_uid_buf: [32]u8 = undefined;
        const len = try lock.readPositionalAll(io, &next_uid_buf, 0);

        var next_uid: u32 = 60000;
        if (len > 0) {
            const clean_global = std.mem.trim(u8, next_uid_buf[0..len], " \n\r");
            next_uid = try std.fmt.parseInt(u32, clean_global, 10);
        }

        const new_next_uid_txt = try gpa.print("{d}", .{next_uid + 1});
        defer gpa.free(new_next_uid_txt);
        try lock.writePositionalAll(io, new_next_uid_txt, 0);

        const local_uid_txt = try gpa.print("{d}\n", .{next_uid});
        defer gpa.free(local_uid_txt);

        try domain.write_file_atomic(io, cwd, uid_path, local_uid_txt, .{});
        return next_uid;
    } else return e;
}
