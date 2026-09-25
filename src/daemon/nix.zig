const std = @import("std");
const builtin = @import("builtin");

pub fn query_store_basename(gpa: std.mem.Allocator, client: *std.http.Client, name: []const u8, version: []const u8) ![]const u8 {
    const hydra_url = try std.fmt.allocPrint(
        gpa,
        "https://hydra.nixos.org/job/nixpkgs/unstable/{s}.{s}-linux/{s}",
        .{ name, @tagName(builtin.cpu.arch), version },
    );
    defer gpa.free(hydra_url);

    var buf: [16 << 10]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const res = try client.fetch(
        .{
            .location = .{ .url = hydra_url },
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/json" },
            },
            .response_writer = &writer,
        },
    );
    switch (res.status) {
        .ok => {},
        else => return error.InvalidHttpResponse,
    }
    const written = buf[0..writer.end];
    const job = try std.json.parseFromSlice(struct {
        job: []const u8,
        buildstatus: u16,
        buildoutputs: struct {
            out: struct {
                path: []const u8,
            },
        },
    }, gpa, written, .{
        .ignore_unknown_fields = true,
    });
    defer job.deinit();
    return try gpa.dupe(u8, job.value.buildoutputs.out.path[11..]);
}

pub const NarInfo = struct {
    _buffer: []const u8,
    store_path: []const u8,
    url: []const u8,
    compression: []const u8,
    file_hash: ?[]const u8 = null,
    file_size: u64 = 0,
    nar_hash: []const u8,
    nar_size: u64 = 0,
    references: []const u8 = "",
    deriver: ?[]const u8 = null,
    sig: ?[]const u8 = null,

    pub fn parse(data: []const u8) ?@This() {
        var result: NarInfo = .{
            ._buffer = data,
            .store_path = "",
            .url = "",
            .compression = "",
            .nar_hash = "",
        };

        var iter = std.mem.splitScalar(u8, data, '\n');
        while (iter.next()) |line| {
            if (line.len == 0)
                continue;
            if (val("StorePath:", line)) |v|
                result.store_path = v
            else if (val("URL:", line)) |v|
                result.url = v
            else if (val("Compression:", line)) |v|
                result.compression = v
            else if (val("FileHash:", line)) |v|
                result.file_hash = v
            else if (val("FileSize:", line)) |v|
                result.file_size = std.fmt.parseInt(u64, v, 10) catch 0
            else if (val("NarHash:", line)) |v|
                result.nar_hash = v
            else if (val("NarSize:", line)) |v|
                result.nar_size = std.fmt.parseInt(u64, v, 10) catch 0
            else if (val("References:", line)) |v|
                result.references = v
            else if (val("Deriver:", line)) |v|
                result.deriver = v
            else if (val("Sig:", line)) |v|
                result.sig = v;
        }

        return if (result.store_path.len == 0 or result.url.len == 0)
            null
        else
            result;
    }

    fn val(prefix: []const u8, line: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, line, prefix))
            return null;
        return std.mem.trim(u8, line[prefix.len..], " \r");
    }
    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        gpa.free(self._buffer);
    }
};

pub fn fetch_narinfo(gpa: std.mem.Allocator, client: *std.http.Client, hash: []const u8) !NarInfo {
    const url = try std.fmt.allocPrint(gpa, "https://cache.nixos.org/{s}.narinfo", .{hash});
    defer gpa.free(url);

    var buf: [4 << 10]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const res = try client.fetch(
        .{
            .location = .{ .url = url },
            .response_writer = &writer,
        },
    );
    switch (res.status) {
        .ok => {},
        else => return error.InvalidHttpResponse,
    }
    const data = try gpa.dupe(u8, buf[0..writer.end]);
    return NarInfo.parse(data) orelse error.InvalidNarInfo;
}

pub const Unpacker = struct {
    root: std.Io.Dir,

    fn take(reader: *std.Io.Reader, buf: []u8) ![]const u8 {
        const len = try reader.takeInt(u64, .little);
        if (len > buf.len) return error.TokenTooLong;
        const len_usize: usize = @intCast(len);
        try reader.readSliceAll(buf[0..len_usize]);
        const pad = (8 - (len_usize % 8)) % 8;
        try reader.discardAll(pad);
        return buf[0..len_usize];
    }

    fn expect(reader: *std.Io.Reader, expected: []const u8, buf: []u8) !void {
        const tok = try take(reader, buf);
        if (!std.mem.eql(u8, tok, expected)) return error.UnexpectedToken;
    }

    pub fn init(dir: std.Io.Dir) Unpacker {
        return .{ .root = dir };
    }

    pub fn unpack(self: *Unpacker, io: std.Io, reader: *std.Io.Reader) !void {
        var tok_buf: [512]u8 = undefined;
        try expect(reader, "nix-archive-1", &tok_buf);
        try self.unpack_node(io, reader, self.root, "", &tok_buf);
    }

    fn unpack_node(self: *Unpacker, io: std.Io, reader: *std.Io.Reader, dir: std.Io.Dir, name: []const u8, buf: []u8) !void {
        try expect(reader, "(", buf);
        try expect(reader, "type", buf);
        const type_str = try take(reader, buf);

        if (std.mem.eql(u8, type_str, "directory")) {
            var current_dir: std.Io.Dir = undefined;
            var must_close = false;
            if (name.len == 0) {
                current_dir = dir;
            } else {
                try dir.createDirPath(io, name);
                current_dir = try dir.openDir(io, name, .{});
                must_close = true;
            }
            defer if (must_close) current_dir.close(io);

            while (true) {
                const tok = try take(reader, buf);
                if (std.mem.eql(u8, tok, ")")) break;
                if (!std.mem.eql(u8, tok, "entry")) return error.UnexpectedToken;

                try expect(reader, "(", buf);
                try expect(reader, "name", buf);
                var name_storage: [256]u8 = undefined;
                const entry_name = try take(reader, &name_storage);
                try expect(reader, "node", buf);
                try self.unpack_node(io, reader, current_dir, entry_name, buf);
                try expect(reader, ")", buf);
            }
        } else if (std.mem.eql(u8, type_str, "regular")) {
            var is_exec = false;
            var next_tok = try take(reader, buf);
            if (std.mem.eql(u8, next_tok, "executable")) {
                try expect(reader, "", buf);
                is_exec = true;
                next_tok = try take(reader, buf);
            }
            if (!std.mem.eql(u8, next_tok, "contents")) return error.UnexpectedToken;

            const file_len = try reader.takeInt(u64, .little);
            var file = try dir.createFile(io, name, .{ .truncate = true });
            defer file.close(io);

            var copy_buf: [64 << 10]u8 = undefined;
            var remaining = file_len;
            while (remaining > 0) {
                const to_read: usize = @intCast(@min(remaining, copy_buf.len));
                try reader.readSliceAll(copy_buf[0..to_read]);
                try file.writeStreamingAll(io, copy_buf[0..to_read]);
                remaining -= to_read;
            }
            const pad = (8 - (file_len % 8)) % 8;
            try reader.discardAll(pad);

            if (is_exec) {
                try file.setPermissions(io, .executable_file);
            }

            try expect(reader, ")", buf);
        } else if (std.mem.eql(u8, type_str, "symlink")) {
            try expect(reader, "target", buf);
            var target_buf: [1024]u8 = undefined;
            const target = try take(reader, &target_buf);
            try dir.symLink(io, target, name, .{});
            try expect(reader, ")", buf);
        } else {
            return error.UnknownNodeType;
        }
    }
};

pub fn fetch(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    io: std.Io,
    nar_url: []const u8,
    dest_dir: std.Io.Dir,
) !void {
    const url = try std.fmt.allocPrint(gpa, "https://cache.nixos.org/{s}", .{nar_url});
    defer gpa.free(url);

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    switch (resp.head.status) {
        .ok => {},
        else => return error.InvalidHttpResponse,
    }

    var transfer_buf: [4096]u8 = undefined;
    const http_reader = resp.reader(&transfer_buf);

    var zstd_buf: [std.compress.zstd.default_window_len + std.compress.zstd.block_size_max]u8 = undefined;
    var decompress = std.compress.zstd.Decompress.init(http_reader, &zstd_buf, .{});

    var unp = Unpacker.init(dest_dir);
    try unp.unpack(io, &decompress.reader);
}
