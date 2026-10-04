const std = @import("std");
const builtin = @import("builtin");

pub fn query_store_basename(gpa: std.mem.Allocator, client: *std.http.Client, name: []const u8) ![]const u8 {
    const hydra_url = try gpa.print(
        "https://hydra.nixos.org/job/nixpkgs/unstable/{s}.{s}-linux/latest",
        .{ name, @tagName(builtin.target.cpu.arch) },
    );
    defer gpa.free(hydra_url);

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();
    const res = try client.fetch(
        .{
            .location = .{ .url = hydra_url },
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/json" },
            },
            .response_writer = &allocating.writer,
        },
    );
    switch (res.status) {
        .ok => {},
        .not_found => return error.PackageNotFound,
        else => return error.InvalidHttpResponse,
    }
    const job = try std.json.parseFromSlice(struct {
        job: []const u8,
        buildstatus: u16,
        buildoutputs: struct {
            out: struct {
                path: []const u8,
            },
        },
    }, gpa, allocating.written(), .{
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
    const url = try gpa.print("https://cache.nixos.org/{s}.narinfo", .{hash});
    defer gpa.free(url);

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();
    const res = try client.fetch(
        .{
            .location = .{ .url = url },
            .response_writer = &allocating.writer,
        },
    );
    switch (res.status) {
        .ok => {},
        else => return error.InvalidHttpResponse,
    }
    const data = try allocating.toOwnedSlice();
    errdefer gpa.free(data);
    return NarInfo.parse(data) orelse error.InvalidNarInfo;
}

pub fn fetch(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    io: std.Io,
    nar_url: []const u8,
    dest_path: []const u8,
) !void {
    const url = try gpa.print("https://cache.nixos.org/{s}", .{nar_url});
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
    const http_reader = resp.reader(transfer_buf);

    const zstd_buf = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer gpa.free(zstd_buf);
    var decompress = std.compress.zstd.Decompress.init(http_reader, zstd_buf, .{});

    try Nar.unpack(gpa, io, dest_path, &decompress.reader);
}

pub const Nar = struct {
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
        if (!std.mem.eql(u8, tok, expected)) return error.UnexpectedToken;
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
};
