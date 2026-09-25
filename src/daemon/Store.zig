const std = @import("std");

const paths = @import("../domain/paths.zig");
const nix = @import("nix.zig");

gpa: std.mem.Allocator,
mutex: std.Io.Mutex = .init,

pub fn init(gpa: std.mem.Allocator) @This() {
    return .{
        .gpa = gpa,
    };
}

pub fn deinit(_: *@This()) void {}

pub fn fetch(self: *@This(), io: std.Io, basename: []const u8) !void {
    const gpa = self.gpa;
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);

    const cwd = std.Io.Dir.cwd();

    const root_path = try paths.store(gpa, basename);
    defer gpa.free(root_path);

    if (cwd.access(io, root_path, .{})) |_| {
        return;
    } else |err| if (err != error.FileNotFound) {
        return err;
    }

    var client: std.http.Client = .{
        .io = io,
        .allocator = gpa,
    };
    defer client.deinit();

    var backlog: std.ArrayList([]const u8) = .empty;
    defer {
        for (backlog.items) |i|
            gpa.free(i);
        backlog.deinit(gpa);
    }

    try backlog.append(gpa, try gpa.dupe(u8, basename));

    while (backlog.items.len > 0) {
        const target_store_basename = backlog.items[backlog.items.len - 1];
        const target_store_path = try paths.store(gpa, target_store_basename);
        defer gpa.free(target_store_path);

        if (cwd.access(io, target_store_path, .{})) |_| {
            const popped = backlog.pop().?;
            gpa.free(popped);
            continue;
        } else |err| if (err != error.FileNotFound) {
            return err;
        }

        const nar_info = try nix.fetch_narinfo(gpa, &client, target_store_basename[0..32]);
        defer gpa.free(nar_info._buffer);

        const circular_dep = for (backlog.items[0 .. backlog.items.len - 1]) |pkg| {
            if (std.mem.eql(u8, target_store_basename, pkg))
                break true;
        } else false;

        var has_missing = false;
        if (!circular_dep and nar_info.references.len > 0) {
            var iter = std.mem.splitScalar(u8, nar_info.references, ' ');
            while (iter.next()) |ref| {
                if (ref.len == 0) continue;
                const ref_path = try paths.store(gpa, ref);
                defer gpa.free(ref_path);
                if (cwd.access(io, ref_path, .{})) |_| continue else |_| {}

                var already_in_backlog = false;
                for (backlog.items) |item| {
                    if (std.mem.eql(u8, item, ref)) {
                        already_in_backlog = true;
                        break;
                    }
                }
                if (!already_in_backlog) {
                    try backlog.append(gpa, try gpa.dupe(u8, ref));
                    has_missing = true;
                }
            }
        }
        if (has_missing) continue;

        const temp_store_path = try std.fmt.allocPrint(gpa, "{s}.tmp-{s}", .{ paths.weft_store_dir, target_store_basename[0..32] });
        defer gpa.free(temp_store_path);

        try cwd.createDirPath(io, temp_store_path);
        {
            var temp_dir = try cwd.openDir(io, temp_store_path, .{});
            defer temp_dir.close(io);
            try nix.fetch(gpa, &client, io, nar_info.url, temp_dir);
        }

        try cwd.rename(temp_store_path, cwd, target_store_path, io);

        const popped = backlog.pop().?;
        gpa.free(popped);
    }
}
