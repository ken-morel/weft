const std = @import("std");

const paths = @import("../domain/paths.zig");
const store_path = paths.weft_nix_store;
const nar_path = paths.weft_nix_nar;
const narinfo_path = paths.weft_nix_narinfo;
const spawn = @import("../domain/spawn.zig").spawn;
const format_bytes = @import("../util/sizes.zig").format_bytes;
pub const devbox = @import("devbox.zig");
const NarInfo = @import("NarInfo.zig");
const NarUnpacker = @import("NarUnpacker.zig");

const install_lock_path = paths.weft_nix ++ "nar/.lock";
pub fn install_package(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, id: []const u8) !void {
    const l = std.log.scoped(.nix);
    const cwd: std.Io.Dir = .cwd();

    const pkg_store_path = try std.fs.path.join(gpa, &.{ store_path, id });
    defer gpa.free(pkg_store_path);

    if (cwd.access(io, pkg_store_path, .{})) |_| {
        l.debug("package {s} already installed", .{id});
        return;
    } else |err| if (err != error.FileNotFound) return err;

    l.info("resolving package {s}...", .{id});
    const narinfo = try fetch_narinfo(gpa, io, client, id);
    defer narinfo.deinit(gpa);
    try cache_narinfo(io, narinfo, false);

    const Spawn = struct {
        fn func(tgpa: std.mem.Allocator, tio: std.Io, tclient: *std.http.Client, tnarinfo: NarInfo, tforce: bool) !void {
            try download_nar(tgpa, tio, tclient, tnarinfo, tforce);
        }
    };

    var group: std.Io.Group = .init;
    try spawn(io, &group, Spawn.func, .{ gpa, io, client, narinfo, false });

    if (narinfo.has_deps()) {
        var deps = narinfo.deps();
        while (deps.next()) |dep| {
            if (dep.len == 0 or std.mem.eql(u8, dep, id))
                continue;
            l.info("installing dependency {s} of {s}", .{ dep, id });
            try install_package(gpa, io, client, dep);
        }
    }

    try group.await(io);
    try install_nar(gpa, io, id, narinfo.compression);
}

pub fn fetch_narinfo(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, id: []const u8) !NarInfo {
    const cwd: std.Io.Dir = .cwd();
    const filename = std.fs.path.basename(id);
    if (cwd.openDir(io, narinfo_path, .{})) |narinfo_dir| {
        defer narinfo_dir.close(io);
        if (narinfo_dir.readFileAlloc(io, filename, gpa, .unlimited)) |content|
            return NarInfo.parse(content) orelse error.InvalidNarInfo
        else |err| if (err != error.FileNotFound)
            return err;
    } else |err| if (err != error.FileNotFound)
        return err;

    return try NarInfo.fetch(gpa, client, filename);
}

pub fn cache_narinfo(io: std.Io, info: NarInfo, force: bool) !void {
    const cwd: std.Io.Dir = .cwd();
    const narinfo_dir = try cwd.openDir(io, narinfo_path, .{});
    defer narinfo_dir.close(io);

    const filename = std.fs.path.basename(info.store_path);
    var atomic = try narinfo_dir.createFileAtomic(io, filename, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);

    try atomic.file.writeStreamingAll(io, info.raw);
    if (force)
        try atomic.replace(io)
    else
        atomic.link(io) catch |err|
            if (err != error.PathAlreadyExists)
                return err;
}

pub fn download_nar(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, narinfo: NarInfo, force: bool) !void {
    const l = std.log.scoped(.nix);
    const cwd: std.Io.Dir = .cwd();
    const nar_dir = try cwd.openDir(io, nar_path, .{});
    defer nar_dir.close(io);

    const id = std.fs.path.basename(narinfo.store_path);

    if (!force)
        if (nar_dir.access(io, id, .{})) |_|
            return
        else |e| if (e != error.FileNotFound)
            return e;

    var size_buf: [32]u8 = undefined;
    const size_str = format_bytes(&size_buf, narinfo.file_size) catch "...";
    l.info("downloading {s} ({s})...", .{ id, size_str });

    const url = try gpa.print("https://cache.nixos.org/{s}", .{narinfo.url});
    defer gpa.free(url);

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @fromBackingInt(@intCast(3)),
    });
    defer req.deinit();

    try req.sendBodiless();

    const redirect_buf = try gpa.alloc(u8, 8 << 10);
    defer gpa.free(redirect_buf);
    var resp = try req.receiveHead(redirect_buf);
    switch (resp.head.status) {
        .ok => {},
        else => return error.InvalidHttpResponse,
    }

    const transfer_buf = try gpa.alloc(u8, 4 << 10);
    defer gpa.free(transfer_buf);
    const http_reader = resp.reader(transfer_buf);

    var atomic = try nar_dir.createFileAtomic(io, id, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    var buf: [4 << 10]u8 = undefined;

    var writer = atomic.file.writer(io, &buf);
    _ = try http_reader.streamRemaining(&writer.interface);
    try writer.interface.flush();

    try atomic.replace(io);
    l.info("downloaded {s}", .{id});
}

pub fn install_nar(gpa: std.mem.Allocator, io: std.Io, id: []const u8, compression: []const u8) !void {
    const l = std.log.scoped(.nix);
    const cwd: std.Io.Dir = .cwd();
    const pkg_store_path = try std.fs.path.join(gpa, &.{ store_path, id });
    defer gpa.free(pkg_store_path);

    const lock = try cwd.createFile(
        io,
        install_lock_path,
        .{
            .lock = .exclusive,
            .lock_nonblocking = false,
        },
    );
    defer lock.close(io);

    if (cwd.access(io, pkg_store_path, .{})) |_|
        return
    else |err| if (err != error.FileNotFound) return err;

    l.info("decompressing and unpacking {s} ({s})...", .{ id, compression });

    const nar_dir = try cwd.openDir(io, nar_path, .{});
    defer nar_dir.close(io);

    const file = try nar_dir.openFile(io, id, .{ .mode = .read_only });
    defer file.close(io);

    var reader_buf: [4 << 10]u8 = undefined;
    var file_reader = file.reader(io, &reader_buf);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp-{d}", .{ pkg_store_path, std.os.linux.getpid() });
    defer gpa.free(tmp_path);
    defer cwd.deleteTree(io, tmp_path) catch {};

    if (std.mem.eql(u8, compression, "zstd")) {
        const zstd_buf = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        defer gpa.free(zstd_buf);
        var decompress = std.compress.zstd.Decompress.init(&file_reader.interface, zstd_buf, .{});
        try NarUnpacker.unpack(gpa, io, tmp_path, &decompress.reader);
    } else if (std.mem.eql(u8, compression, "xz")) {
        const xz_buf = try gpa.alloc(u8, 8 << 20);
        defer gpa.free(xz_buf);
        var decompress = try std.compress.xz.Decompress.init(&file_reader.interface, gpa, xz_buf);
        defer decompress.deinit();
        try NarUnpacker.unpack(gpa, io, tmp_path, &decompress.reader);
    } else if (std.mem.eql(u8, compression, "none") or compression.len == 0) {
        try NarUnpacker.unpack(gpa, io, tmp_path, &file_reader.interface);
    } else {
        l.err("unsupported compression '{s}' for {s}", .{ compression, id });
        return error.UnsupportedCompression;
    }

    try std.Io.Dir.renameAbsolute(tmp_path, pkg_store_path, io);
    l.info("installed {s}", .{id});
}
