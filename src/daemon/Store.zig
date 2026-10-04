const std = @import("std");

const paths = @import("../domain/paths.zig");
const Term = @import("../domain/Term.zig");
const sizes = @import("../util/sizes.zig");
const DaemonInstall = @import("DaemonInstall.zig");
const nix = @import("nix.zig");

gpa: std.mem.Allocator,
term: *Term,
mutex: std.Io.Mutex = .init,

pub fn init(gpa: std.mem.Allocator, term: *Term) @This() {
    return .{
        .gpa = gpa,
        .term = term,
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
        self.term.debug("nix::store package {s} already in store", .{basename});
        return;
    } else |err| if (err != error.FileNotFound)
        return err;

    self.term.info("nix::store fetching {s}...", .{basename});

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
        const store_basename = backlog.items[backlog.items.len - 1];
        const store_path = try paths.store(gpa, store_basename);
        defer gpa.free(store_path);

        if (cwd.access(io, store_path, .{})) |_| {
            const popped = backlog.pop().?;
            gpa.free(popped);
            continue;
        } else |err| if (err != error.FileNotFound)
            return err;

        const nar_info = try nix.fetch_narinfo(gpa, &client, store_basename[0..32]);
        defer nar_info.deinit(gpa);

        const circular_dep = for (backlog.items[0 .. backlog.items.len - 1]) |pkg| {
            if (std.mem.eql(u8, store_basename, pkg))
                break true;
        } else false;

        var has_missing_dep = false;
        if (!circular_dep and nar_info.references.len > 0) {
            var iter = std.mem.splitScalar(u8, nar_info.references, ' ');
            while (iter.next()) |ref| {
                if (ref.len == 0) continue;
                const ref_path = try paths.store(gpa, ref);
                defer gpa.free(ref_path);
                if (cwd.access(io, ref_path, .{})) |_| continue else |_| {}

                const already_in_backlog = for (backlog.items) |item| {
                    if (std.mem.eql(u8, item, ref))
                        break true;
                } else false;
                if (!already_in_backlog) {
                    try backlog.append(gpa, try gpa.dupe(u8, ref));
                    has_missing_dep = true;
                }
            }
        }
        if (has_missing_dep)
            continue
        else {
            const temp_dir = try DaemonInstall.open_temp(io, "nix-pkg");
            defer temp_dir.close(io);
            const temp_dir_path = try temp_dir.realPathFileAlloc(io, ".", gpa);
            defer gpa.free(temp_dir_path);
            defer cwd.deleteTree(io, temp_dir_path) catch {};

            var size_buf: [1 << 6]u8 = undefined;
            self.term.info("nix::store downloading {s} ({s})...", .{ store_basename, sizes.format_bytes(&size_buf, nar_info.file_size) });

            const temp_store_path = try std.fs.path.join(gpa, &.{ temp_dir_path, store_basename });
            defer gpa.free(temp_store_path);
            try nix.fetch(std.heap.page_allocator, &client, io, nar_info.url, temp_store_path);

            var children = temp_dir.iterate();
            var store_dir = try cwd.openDir(io, paths.weft_store_dir, .{});
            defer store_dir.close(io);
            while (try children.next(io)) |entry|
                try temp_dir.rename(entry.name, store_dir, entry.name, io);

            self.term.info("nix::store installed {s}", .{store_basename});
        }

        const popped = backlog.pop().?;
        gpa.free(popped);
    }

    self.term.info("nix::store finished installing {s}", .{basename});
}
