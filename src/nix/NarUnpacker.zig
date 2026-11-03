const std = @import("std");

fn take(reader: *std.Io.Reader, buf: []u8) ![]const u8 {
    const len = try reader.takeInt(u64, .little);
    if (len > buf.len)
        return error.TokenTooLong;

    const len_usize: usize = @intCast(len);

    try reader.readSliceAll(buf[0..len_usize]);
    const pad = (8 - (len_usize % 8)) % 8;
    try reader.discardAll(pad);
    return buf[0..len_usize];
}

fn expect(reader: *std.Io.Reader, expected: []const u8, buf: []u8) !void {
    const tok = try take(reader, buf);
    if (!std.mem.eql(u8, tok, expected))
        return error.UnexpectedToken;
}

fn check_name(name: []const u8) !void {
    if (name.len == 0 or
        std.mem.findAny(u8, name, &.{ '/', 0 }) != null or
        std.mem.startsWith(u8, name, "..") or std.mem.eql(u8, name, "."))
    {
        std.log.scoped(.nix_nar).err("Invalid archive name: {s}", .{name});
        return error.InvalidArchivePath;
    }
}
pub fn unpack(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    r: *std.Io.Reader,
) !void {
    const cwd = std.Io.Dir.cwd();
    const tok_buf = try gpa.alloc(u8, 4 << 10);
    defer gpa.free(tok_buf);

    const copy_buf = try gpa.alloc(u8, 64 << 10);
    defer gpa.free(copy_buf);

    try expect(r, "nix-archive-1", tok_buf);

    var path_buf: [4 << 10]u8 = undefined;
    var path_len: usize = 0;

    @memcpy(path_buf[0..root.len], root);
    path_len = root.len;

    const State = struct {
        ctx: enum { dir_node, entry },
        prev_len: usize,
    };
    var stack: std.ArrayList(State) = .empty;
    defer stack.deinit(gpa);

    while (true) {
        const tok = take(r, tok_buf) catch |err| {
            if (err == error.EndOfStream)
                break;
            return err;
        };

        if (std.mem.eql(u8, tok, "(")) {
            const next = try take(r, tok_buf);

            if (std.mem.eql(u8, next, "type")) {
                const type_str = try take(r, tok_buf);
                const current_path = path_buf[0..path_len];

                if (std.mem.eql(u8, type_str, "directory")) {
                    try cwd.createDirPath(io, current_path);
                    try stack.append(gpa, .{ .ctx = .dir_node, .prev_len = path_len });
                } else if (std.mem.eql(u8, type_str, "regular")) {
                    var next_tok = try take(r, tok_buf);

                    const is_exec = if (std.mem.eql(u8, next_tok, "executable")) blk: {
                        try expect(r, "", tok_buf);
                        next_tok = try take(r, tok_buf);
                        break :blk true;
                    } else false;
                    if (!std.mem.eql(u8, next_tok, "contents"))
                        return error.UnexpectedToken;

                    const file_len = try r.takeInt(u64, .little);

                    var file = try cwd.createFile(io, current_path, .{ .truncate = true });
                    defer file.close(io);

                    var remaining = file_len;
                    while (remaining > 0) {
                        const to_read: usize = @intCast(@min(remaining, copy_buf.len));
                        try r.readSliceAll(copy_buf[0..to_read]);
                        try file.writeStreamingAll(io, copy_buf[0..to_read]);
                        remaining -= to_read;
                    }

                    const pad = (8 - (file_len % 8)) % 8;
                    try r.discardAll(pad);

                    if (is_exec)
                        try file.setPermissions(io, .executable_file);

                    try expect(r, ")", tok_buf);
                } else if (std.mem.eql(u8, type_str, "symlink")) {
                    try expect(r, "target", tok_buf);
                    const target = try take(r, copy_buf);
                    try cwd.symLink(io, target, current_path, .{});
                    try expect(r, ")", tok_buf);
                } else return error.UnknownNodeType;
            } else if (std.mem.eql(u8, next, "name")) {
                try stack.append(gpa, .{ .ctx = .entry, .prev_len = path_len });

                const start_idx = path_len + 1;
                if (start_idx >= path_buf.len) return error.PathTooLong;

                const entry_name = try take(r, path_buf[start_idx..]);

                try check_name(entry_name);
                try expect(r, "node", tok_buf);

                path_buf[path_len] = '/';
                path_len = start_idx + entry_name.len;
            } else return error.UnexpectedToken;
        } else if (std.mem.eql(u8, tok, ")")) {
            if (stack.pop()) |state| {
                if (state.ctx == .entry)
                    path_len = state.prev_len;
            } else break;
        } else if (std.mem.eql(u8, tok, "entry")) {
            // nothing
        } else return error.UnexpectedToken;
    }
}
