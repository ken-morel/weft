const std = @import("std");

const paths = @import("../domain/paths.zig");

pub fn workspace_uid(gpa: std.mem.Allocator, io: std.Io, workspace: []const u8) !u32 {
    const uid_path = try gpa.print(paths.workspace_uid, .{workspace});
}

/// Get or allocate a persistent UID/GID for a workspace.
pub fn _workspace_uid(alloc: std.mem.Allocator, io: std.Io, workspace: []const u8) !u32 {
    const home_path = try std.fs.path.join(alloc, &.{ paths.weft_home_dir, workspace });
    var home_dir = try std.Io.Dir.cwd().createDirPathOpen(io, home_path, .{});
    defer home_dir.close(io);

    // If .uid already exists in /var/lib/weft/home/{w}/.uid, read and return it
    if (home_dir.readFileAlloc(io, ".uid", alloc, .limited(32))) |content| {
        return std.fmt.parseInt(u32, std.mem.trim(u8, content, " \n\r"), 10);
    } else |_| {}

    // Otherwise derive a deterministic UID in 10000..59999 (or increment a counter file)
    const hash = std.hash.Wyhash.hash(0, workspace);
    const uid: u32 = @intCast(10000 + (hash % 50000));

    const uid_str = try std.fmt.allocPrint(alloc, "{d}\n", .{uid});
    try home_dir.writeFile(io, .{ .data = uid_str, .sub_path = ".uid" });

    // Set ownership of /var/lib/weft/home/{w} to uid:uid
    _ = std.os.linux.fchown(home_dir.handle, uid, uid);
    return uid;
}

/// Change ownership of a subdirectory relative to an open parent Dir.
pub fn chown_dir_at(parent: std.Io.Dir, sub_path: [:0]const u8, uid: u32, gid: u32) !void {
    const rc = std.os.linux.fchownat(parent.handle, sub_path.ptr, uid, gid, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.ChownFailed;
}
