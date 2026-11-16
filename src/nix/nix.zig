const std = @import("std");

const paths = @import("../domain/paths.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const format_bytes = @import("../util/sizes.zig").format_bytes;
pub const devbox = @import("devbox.zig");
pub const NarInfo = @import("NarInfo.zig");
const NarUnpacker = @import("NarUnpacker.zig");

const install_lock_path = paths.weft_nix ++ "nar/.lock";
const download_locks_dir = paths.weft_nix ++ "nar/.locks";
const max_http_attempts: usize = 4;

pub fn install_package(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, pkg_id: []const u8) anyerror!void {
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

    var group: std.Io.Group = .init;
    errdefer group.cancel(io);

    try spawn(io, &group, download_nar, .{ gpa, io, client, narinfo, false });

    if (narinfo.has_deps()) {
        var deps = narinfo.deps();
        while (deps.next()) |dep| {
            if (dep.len == 0 or std.mem.eql(u8, dep, pkg_id))
                continue;
            l.info("installing dependency {s} of {s}", .{ dep, pkg_id });
            try spawn(io, &group, install_package, .{ gpa, io, client, dep });
        }
    }

    try group.await(io);

    install_nar(gpa, io, narinfo) catch |err| {
        l.warn("failed to unpack nar for {s} ({s}), refetching...", .{ pkg_id, @errorName(err) });
        const fresh_narinfo = try fetch_narinfo_remote(gpa, io, client, pkg_hash);
        defer fresh_narinfo.deinit(gpa);
        try cache_narinfo(gpa, io, fresh_narinfo, true);
        try download_nar(gpa, io, client, fresh_narinfo, true);
        try install_nar(gpa, io, fresh_narinfo);
    };
}

fn fetch_narinfo_remote(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, hash: []const u8) !NarInfo {
    const l = std.log.scoped(.nix);
    l.debug("fetching narinfo for {s} from cache.nixos.org...", .{hash});

    var attempt: usize = 0;
    while (true) {
        return NarInfo.fetch(gpa, client, hash) catch |err| {
            if (attempt + 1 >= max_http_attempts or err == error.InvalidHash or err == error.InvalidNarInfo)
                return err;
            l.warn("narinfo fetch failed for {s} ({s}), retrying ({d}/{d})...", .{
                hash,
                @errorName(err),
                attempt + 1,
                max_http_attempts - 1,
            });
            try std.Io.sleep(io, .fromSeconds(5), .awake);
            attempt += 1;
            continue;
        };
    }
}

pub fn fetch_narinfo(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, hash: []const u8) !NarInfo {
    if (hash.len != 32)
        return error.InvalidHash;
    const cwd: std.Io.Dir = .cwd();
    const path = try gpa.print(paths.weft_nix_narinfo_file, .{hash});
    defer gpa.free(path);
    if (cwd.openDir(io, paths.weft_nix_narinfo, .{})) |narinfo_dir| {
        defer narinfo_dir.close(io);
        if (narinfo_dir.readFileAlloc(io, path, gpa, .unlimited)) |content| {
            if (NarInfo.parse(content)) |info|
                return info;
            gpa.free(content);
            std.log.scoped(.nix).warn("cached narinfo for {s} is invalid, refetching...", .{hash});
            narinfo_dir.deleteFile(io, path) catch {};
        } else |err| if (err != error.FileNotFound)
            return err;
    } else |err| if (err != error.FileNotFound)
        return err;

    return try fetch_narinfo_remote(gpa, io, client, hash);
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

fn parse_nix_sha256(encoded: []const u8) ?[32]u8 {
    if (std.mem.startsWith(u8, encoded, "sha256:")) {
        const val = encoded["sha256:".len..];
        if (val.len == 52) {
            const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
            var out: [32]u8 = @splat(0);
            for (0..val.len) |i| {
                const c = val[val.len - 1 - i];
                const digit: u8 = @intCast(std.mem.indexOfScalar(u8, alphabet, c) orelse return null);
                const bit_pos = i * 5;
                const byte_idx = bit_pos / 8;
                const bit_idx: u3 = @intCast(bit_pos % 8);
                out[byte_idx] |= digit << bit_idx;
                if (bit_idx > 3) {
                    const overflow = digit >> @intCast(8 - @as(u4, bit_idx));
                    if (byte_idx + 1 < out.len) {
                        out[byte_idx + 1] |= overflow;
                    } else if (overflow != 0) {
                        return null;
                    }
                }
            }
            return out;
        }
        if (val.len == 64) {
            var out: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&out, val) catch return null;
            return out;
        }
        return null;
    }
    if (std.mem.startsWith(u8, encoded, "sha256-")) {
        const val = encoded["sha256-".len..];
        var out: [32]u8 = undefined;
        std.base64.standard.Decoder.decode(&out, val) catch return null;
        return out;
    }
    return null;
}

fn verify_nar_file(io: std.Io, file: std.Io.File, narinfo: NarInfo) !bool {
    const stat = try file.stat(io);
    if (narinfo.file_size > 0 and stat.size != narinfo.file_size)
        return false;

    const expected = if (narinfo.file_hash) |h| parse_nix_sha256(h) else null;
    if (expected == null)
        return true;

    var buf: [16 << 10]u8 = undefined;
    var reader = file.reader(io, &buf);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    while (true) {
        const slice = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        hasher.update(slice);
        reader.interface.toss(slice.len);
    }

    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    return std.mem.eql(u8, &actual, &expected.?);
}

fn check_content_range_offset(head: std.http.Client.Response.Head, expected_offset: u64) bool {
    var prefix_buf: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "bytes {d}-", .{expected_offset}) catch return false;

    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-range"))
            return std.mem.startsWith(u8, header.value, prefix);
    }
    return false;
}

pub fn download_nar(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, narinfo: NarInfo, force: bool) !void {
    const l = std.log.scoped(.nix);
    const cwd: std.Io.Dir = .cwd();

    const pkg_id = std.fs.path.basename(narinfo.store_path);
    const pkg_hash = pkg_id[0..32];

    const locks_dir = try cwd.createDirPathOpen(io, download_locks_dir, .{});
    defer locks_dir.close(io);
    const dl_lock = try locks_dir.createFile(io, pkg_hash, .{
        .lock = .exclusive,
        .lock_nonblocking = false,
        .truncate = false,
    });
    defer dl_lock.close(io);

    const nar_dir = try cwd.openDir(io, paths.weft_nix_nar, .{});
    defer nar_dir.close(io);

    const url = try gpa.print("https://cache.nixos.org/{s}", .{narinfo.url});
    defer gpa.free(url);

    const nar_name = std.fs.path.basename(narinfo.url);

    if (!force)
        if (nar_dir.statFile(io, nar_name, .{})) |stat| {
            if (narinfo.file_size == 0 or stat.size == narinfo.file_size)
                return;
            l.warn("cached nar {s} size mismatch ({d} != {d}), redownloading...", .{
                nar_name,
                stat.size,
                narinfo.file_size,
            });
        } else |e| if (e != error.FileNotFound)
            return e;

    const part_name = try gpa.print("{s}.part", .{nar_name});
    defer gpa.free(part_name);

    var part_file = try nar_dir.createFile(io, part_name, .{
        .read = true,
        .truncate = force,
    });
    defer part_file.close(io);

    var size_buf: [32]u8 = undefined;
    const size_str = format_bytes(&size_buf, narinfo.file_size) catch "...";

    const initial_stat = try part_file.stat(io);
    if (narinfo.file_size > 0 and initial_stat.size > narinfo.file_size) {
        l.warn("partial file {s} exceeds expected size ({d} > {d}), restarting...", .{
            part_name,
            initial_stat.size,
            narinfo.file_size,
        });
        try part_file.setLength(io, 0);
    } else if (initial_stat.size > 0) {
        var off_buf: [32]u8 = undefined;
        const off_str = format_bytes(&off_buf, initial_stat.size) catch "...";
        l.info("resuming {s} for {s} ({s} / {s})...", .{ nar_name, pkg_id, off_str, size_str });
    } else {
        l.info("downloading {s} for {s} ({s})...", .{ nar_name, pkg_id, size_str });
    }

    const redirect_buf = try gpa.alloc(u8, 8 << 10);
    defer gpa.free(redirect_buf);
    const transfer_buf = try gpa.alloc(u8, 4 << 10);
    defer gpa.free(transfer_buf);

    var attempt: usize = 0;
    while (attempt < max_http_attempts) : (attempt += 1) {
        const offset = (try part_file.stat(io)).size;
        if (narinfo.file_size > 0 and offset == narinfo.file_size) {
            l.debug("verifying {s} ({s})...", .{ nar_name, size_str });
            if (try verify_nar_file(io, part_file, narinfo)) {
                try nar_dir.rename(part_name, nar_dir, nar_name, io);
                l.info("downloaded {s}", .{nar_name});
                return;
            }
            l.warn("verification failed for {s}, restarting download...", .{nar_name});
            try part_file.setLength(io, 0);
        }

        const dl_result = download_attempt(
            io,
            client,
            url,
            part_file,
            (try part_file.stat(io)).size,
            redirect_buf,
            transfer_buf,
        );

        if (dl_result) |_| {
            l.debug("verifying {s} ({s})...", .{ nar_name, size_str });
            if (try verify_nar_file(io, part_file, narinfo)) {
                try nar_dir.rename(part_name, nar_dir, nar_name, io);
                l.info("downloaded {s}", .{nar_name});
                return;
            }
            l.warn("verification failed for {s}, restarting download...", .{nar_name});
            try part_file.setLength(io, 0);
        } else |err| {
            if (err == error.Canceled)
                return err;
            if (attempt + 1 >= max_http_attempts)
                return err;
            l.warn("download failed for {s} ({s}), retrying  ({d}/{d})...", .{
                nar_name,
                @errorName(err),
                attempt + 1,
                max_http_attempts - 1,
            });
            try std.Io.sleep(io, .fromSeconds(5), .awake);
        }
    }

    return error.DownloadFailed;
}

fn download_attempt(
    io: std.Io,
    client: *std.http.Client,
    url: []const u8,
    part_file: std.Io.File,
    initial_offset: u64,
    redirect_buf: []u8,
    transfer_buf: []u8,
) !void {
    var range_buf: [48]u8 = undefined;
    var headers_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (initial_offset > 0) blk: {
        const range_val = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{initial_offset});
        headers_buf[0] = .{ .name = "Range", .value = range_val };
        break :blk &headers_buf;
    } else &.{};

    var req = try client.request(.GET, try .parse(url), .{
        .redirect_behavior = @fromBackingInt(@intCast(5)),
        .extra_headers = extra_headers,
    });
    defer req.deinit();

    try req.sendBodiless();

    var resp = try req.receiveHead(redirect_buf);
    var write_offset: u64 = initial_offset;
    switch (resp.head.status) {
        .ok => {
            if (initial_offset > 0) {
                try part_file.setLength(io, 0);
                write_offset = 0;
            }
        },
        .partial_content => {
            if (initial_offset > 0 and !check_content_range_offset(resp.head, initial_offset)) {
                try part_file.setLength(io, 0);
                return error.InvalidContentRange;
            }
        },
        .range_not_satisfiable => {
            try part_file.setLength(io, 0);
            return error.RangeNotSatisfiable;
        },
        .too_many_requests, .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => {
            return error.TransientHttpError;
        },
        else => return error.InvalidHttpResponse,
    }

    const http_reader = resp.reader(transfer_buf);
    var buf: [16 << 10]u8 = undefined;
    var writer = part_file.writer(io, &buf);
    try writer.seekTo(write_offset);
    _ = http_reader.streamRemaining(&writer.interface) catch |err| {
        writer.interface.flush() catch {};
        return err;
    };
    try writer.interface.flush();
}

pub fn install_nar(gpa: std.mem.Allocator, io: std.Io, narinfo: NarInfo) !void {
    const l = std.log.scoped(.nix);
    const cwd: std.Io.Dir = .cwd();
    const nar_name = std.fs.path.basename(narinfo.url);
    const pkg_id = std.fs.path.basename(narinfo.store_path);
    const pkg_store_path = try std.fs.path.join(gpa, &.{ paths.weft_nix_store, pkg_id });
    defer gpa.free(pkg_store_path);

    l.debug("waiting for install lock for {s}...", .{pkg_id});
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
    } else if (std.mem.eql(u8, narinfo.compression, "none") or narinfo.compression.len == 0)
        try NarUnpacker.unpack(gpa, io, tmp_path, &file_reader.interface)
    else {
        l.err("unsupported compression '{s}' for {s}", .{ narinfo.compression, pkg_id });
        return error.UnsupportedCompression;
    }

    try std.Io.Dir.renameAbsolute(tmp_path, pkg_store_path, io);
    l.info("installed {s}", .{pkg_id});
}
