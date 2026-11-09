const std = @import("std");

const paths = @import("../domain/paths.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const format_bytes = @import("../util/sizes.zig").format_bytes;
pub const devbox = @import("devbox.zig");
const NarInfo = @import("NarInfo.zig");
const NarUnpacker = @import("NarUnpacker.zig");

const install_lock_path = paths.weft_nix ++ "nar/.lock";
pub fn install_package(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, pkg_id: []const u8) !void {
    const l = std.log.scoped(.nix);
    const cwd: std.Io.Dir = .cwd();

    const pkg_hash = pkg_id[0..32];

    const pkg_store_path = try std.fs.path.join(gpa, &.{ paths.weft_nix_store, pkg_id });
    defer gpa.free(pkg_store_path);

    if (cwd.access(io, pkg_store_path, .{})) |_| {
        l.debug("package {s} already installed", .{pkg_id});
        return;
    } else |err| if (err != error.FileNotFound)
        return err;

    l.info("resolving package {s}...", .{pkg_id});
    const narinfo = try fetch_narinfo(gpa, io, client, pkg_hash);
    defer narinfo.deinit(gpa);
    try cache_narinfo(gpa, io, narinfo, false);

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
            if (dep.len == 0 or std.mem.eql(u8, dep, pkg_id))
                continue;
            l.info("installing dependency {s} of {s}", .{ dep, pkg_id });
            try install_package(gpa, io, client, dep);
        }
    }

    try group.await(io);
    try install_nar(gpa, io, narinfo);
}

pub fn fetch_narinfo(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, hash: []const u8) !NarInfo {
    if (hash.len != 32)
        return error.InvalidHash;
    const cwd: std.Io.Dir = .cwd();
    const path = try gpa.print(paths.weft_nix_narinfo_file, .{hash});
    defer gpa.free(path);
    if (cwd.openDir(io, paths.weft_nix_narinfo, .{})) |narinfo_dir| {
        defer narinfo_dir.close(io);
        if (narinfo_dir.readFileAlloc(io, path, gpa, .unlimited)) |content|
            return NarInfo.parse(content) orelse error.InvalidNarInfo
        else |err| if (err != error.FileNotFound)
            return err;
    } else |err| if (err != error.FileNotFound)
        return err;

    return try NarInfo.fetch(gpa, client, hash);
}

pub fn cache_narinfo(gpa: std.mem.Allocator, io: std.Io, info: NarInfo, force: bool) !void {
    const cwd: std.Io.Dir = .cwd();
    const narinfo_dir = try cwd.openDir(io, paths.weft_nix_narinfo, .{});
    defer narinfo_dir.close(io);

    const hash = std.fs.path.basename(info.store_path)[0..32];
    const filename = try gpa.print(paths.weft_nix_narinfo_file, .{hash});
    defer gpa.free(filename);
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
    const nar_dir = try cwd.openDir(io, paths.weft_nix_nar, .{});
    defer nar_dir.close(io);

    const url = try gpa.print("https://cache.nixos.org/{s}", .{narinfo.url});
    defer gpa.free(url);

    const nar_name = std.fs.path.basename(narinfo.url);

    if (!force)
        if (nar_dir.access(io, nar_name, .{})) |_|
            return
        else |e| if (e != error.FileNotFound)
            return e;

    var size_buf: [32]u8 = undefined;
    const size_str = format_bytes(&size_buf, narinfo.file_size) catch "...";
    l.info("downloading {s} for {s} ({s})...", .{ nar_name, std.fs.path.basename(narinfo.store_path), size_str });

    var req = try client.request(.GET, try .parse(url), .{
        .redirect_behavior = @fromBackingInt(@intCast(5)),
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

    var atomic = try nar_dir.createFileAtomic(io, nar_name, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    var buf: [4 << 10]u8 = undefined;

    var writer = atomic.file.writer(io, &buf);
    _ = try http_reader.streamRemaining(&writer.interface);
    try writer.interface.flush();

    try atomic.replace(io);
    l.info("downloaded {s}", .{nar_name});
}

pub fn install_nar(gpa: std.mem.Allocator, io: std.Io, narinfo: NarInfo) !void {
    const l = std.log.scoped(.nix);
    const cwd: std.Io.Dir = .cwd();
    const nar_name = std.fs.path.basename(narinfo.url);
    const pkg_id = std.fs.path.basename(narinfo.store_path);
    const pkg_store_path = try std.fs.path.join(gpa, &.{ paths.weft_nix_store, pkg_id });
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

    l.info("decompressing and unpacking {s} ({s})...", .{ pkg_id, narinfo.compression });

    const nar_dir = try cwd.openDir(io, paths.weft_nix_nar, .{});
    defer nar_dir.close(io);

    const file = try nar_dir.openFile(io, nar_name, .{ .mode = .read_only });
    defer file.close(io);

    var reader_buf: [4 << 10]u8 = undefined;
    var file_reader = file.reader(io, &reader_buf);

    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp-{d}", .{ pkg_store_path, std.os.linux.getpid() });
    defer gpa.free(tmp_path);
    defer cwd.deleteTree(io, tmp_path) catch {};

    if (std.mem.eql(u8, narinfo.compression, "zstd")) {
        const zstd_buf = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        defer gpa.free(zstd_buf);
        var decompress = std.compress.zstd.Decompress.init(&file_reader.interface, zstd_buf, .{});
        try NarUnpacker.unpack(gpa, io, tmp_path, &decompress.reader);
    } else if (std.mem.eql(u8, narinfo.compression, "xz")) {
        const xz_buf = try gpa.alloc(u8, 8 << 20);
        defer gpa.free(xz_buf);
        var decompress = try std.compress.xz.Decompress.init(&file_reader.interface, gpa, xz_buf);
        defer decompress.deinit();
        try NarUnpacker.unpack(gpa, io, tmp_path, &decompress.reader);
    } else if (std.mem.eql(u8, narinfo.compression, "none") or narinfo.compression.len == 0) {
        try NarUnpacker.unpack(gpa, io, tmp_path, &file_reader.interface);
    } else {
        l.err("unsupported compression '{s}' for {s}", .{ narinfo.compression, pkg_id });
        return error.UnsupportedCompression;
    }

    try std.Io.Dir.renameAbsolute(tmp_path, pkg_store_path, io);
    l.info("installed {s}", .{pkg_id});
}
