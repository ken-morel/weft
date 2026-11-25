const std = @import("std");
const log = std.log.scoped;

const ClientInstall = @import("client/ClientInstall.zig");
const Deployment = @import("client/Deployment.zig");
const DaemonInstall = @import("daemon/DaemonInstall.zig");
const domain = @import("domain/domain.zig");
const proto = @import("domain/proto.zig");
const Task = @import("domain/Task.zig");
const Weft = @import("domain/Weft.zig");
const Monitor = @import("util/Monitor.zig");
const zoto = @import("util/zoto.zig");
const zoton = @import("util/zoton.zig");

pub const types = [_]type{
    Task.Status,
    Task.Spec,
    Task,
    Task.Id,

    Deployment,
    Weft,
    Monitor.Stats,

    DaemonInstall.Config,
    ClientInstall.Config,

    proto.Request,
    proto.DaemonMsg,

    proto.artifact.push.Req,
    proto.artifact.push.Res,
    proto.R(proto.artifact.push.Res),

    proto.artifact.pull.Req,
    proto.artifact.pull.Res,
    proto.R(proto.artifact.pull.Res),

    proto.artifact.has.Req,
    proto.artifact.has.Res,
    proto.R(proto.artifact.has.Res),

    proto.task.spawn.Req,
    proto.task.spawn.Res,
    proto.R(proto.task.spawn.Res),

    proto.task.poll.Req,
    proto.task.poll.Res,
    proto.R(proto.task.poll.Res),

    proto.task.kill.Req,
    proto.task.kill.Res,
    proto.R(proto.task.kill.Res),

    proto.system.stats.Req,

    proto.Pack,
};

pub fn decode_to_zoton(
    gpa: std.mem.Allocator,
    raw: []const u8,
    out: *std.Io.Writer,
) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const has_header = std.mem.startsWith(u8, raw, "ZOTO");
    const data = if (has_header) raw[4..] else raw;

    if (data.len < @sizeOf(u64))
        return error.BufferTooSmall;

    const hash = std.mem.readInt(u64, data[0..@sizeOf(u64)], .little);
    const payload = data[@sizeOf(u64)..];

    inline for (types) |T| {
        if (hash == comptime zoto.hashType(T)) {
            var parse_slice = payload;
            const val = try zoto.deserialize(alloc, &parse_slice, T, .{
                .header = false,
                .hash = false,
            });

            try out.print("// zoto: {s}\n", .{@typeName(T)});
            try out.print("// header: {}\n", .{has_header});
            try zoton.serialize(out, T, val);
            try out.writeByte('\n');
            if (parse_slice.len > 0)
                try out.print("// trailing: {d} bytes\n", .{parse_slice.len});
            return;
        }
    }

    return error.UnknownTypeHash;
}

const ZotonMeta = struct {
    type_name: ?[]const u8 = null,
    header: ?bool = null,
};

fn parse_zoton_meta(source: []const u8) ZotonMeta {
    var meta: ZotonMeta = .{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0)
            continue;
        if (!std.mem.startsWith(u8, line, "//"))
            break;
        const body = std.mem.trim(u8, line[2..], " \t");
        if (std.mem.startsWith(u8, body, "zoto:"))
            meta.type_name = std.mem.trim(u8, body["zoto:".len..], " \t")
        else if (std.mem.startsWith(u8, body, "header:")) {
            const val = std.mem.trim(u8, body["header:".len..], " \t");
            if (std.mem.eql(u8, val, "true"))
                meta.header = true
            else if (std.mem.eql(u8, val, "false"))
                meta.header = false;
        }
    }
    return meta;
}

pub fn encode_from_zoton(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    out: *std.Io.Writer,
    type_override: ?[]const u8,
    header_override: ?bool,
) !void {
    const l = log(.zoto_encode);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const meta = parse_zoton_meta(source);
    const type_name = type_override orelse meta.type_name orelse {
        l.err("missing zoto type; add '// zoto: <type>' header or pass --type", .{});
        return error.MissingType;
    };
    const has_header = header_override orelse meta.header orelse true;

    inline for (types) |T| {
        if (std.mem.eql(u8, type_name, @typeName(T))) {
            const val = try zoton.deserialize_leaky(gpa, alloc, source, T);
            try zoto.serialize(out, T, val, .{
                .header = has_header,
                .hash = true,
            });
            return;
        }
    }

    l.err("unknown zoto type '{s}'", .{type_name});
    return error.UnknownType;
}

fn read_input(gpa: std.mem.Allocator, io: std.Io, file: []const u8) ![]u8 {
    return if (std.mem.eql(u8, file, "-")) in: {
        var buf: [4096]u8 = undefined;
        var allocating: std.Io.Writer.Allocating = .init(gpa);
        defer allocating.deinit();

        var stdin_reader = std.Io.File.stdin().readerStreaming(io, &buf);
        _ = try allocating.writer.sendFileReadingAll(&stdin_reader, .unlimited);
        break :in try allocating.toOwnedSlice();
    } else try std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .unlimited);
}

fn read_input_z(gpa: std.mem.Allocator, io: std.Io, file: []const u8) ![:0]u8 {
    return if (std.mem.eql(u8, file, "-")) in: {
        const raw = try read_input(gpa, io, "-");
        defer gpa.free(raw);
        break :in try gpa.dupeSentinel(u8, raw, 0);
    } else try std.Io.Dir.cwd().readFileAllocOptions(io, file, gpa, .unlimited, .of(u8), 0);
}

fn write_output(io: std.Io, out_path: []const u8, bytes: []const u8) !void {
    if (std.mem.eql(u8, out_path, "-")) {
        var buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
        try stdout_writer.interface.writeAll(bytes);
        try stdout_writer.interface.flush();
    } else try domain.write_file_atomic(io, .cwd(), out_path, bytes, .{ .replace = true });
}

pub fn run_decode(
    gpa: std.mem.Allocator,
    io: std.Io,
    file: []const u8,
    out_path: []const u8,
) !void {
    const content = try read_input(gpa, io, file);
    defer gpa.free(content);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try decode_to_zoton(gpa, content, &out.writer);
    try write_output(io, out_path, out.written());
}

pub fn run_encode(
    gpa: std.mem.Allocator,
    io: std.Io,
    file: []const u8,
    out_path: []const u8,
    type_override: ?[]const u8,
    header_override: ?bool,
) !void {
    const source = try read_input_z(gpa, io, file);
    defer gpa.free(source);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try encode_from_zoton(gpa, source, &out.writer, type_override, header_override);
    try write_output(io, out_path, out.written());
}

fn prompt_reopen(io: std.Io) bool {
    const tty = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch return false;
    defer tty.close(io);

    var wbuf: [64]u8 = undefined;
    var w = tty.writerStreaming(io, &wbuf);
    w.interface.writeAll("Re-open editor? [Y/n] ") catch return false;
    w.interface.flush() catch return false;

    var rbuf: [64]u8 = undefined;
    var r = tty.readerStreaming(io, &rbuf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return false;
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return trimmed.len == 0 or (trimmed[0] != 'n' and trimmed[0] != 'N');
}

pub fn run_edit(
    gpa: std.mem.Allocator,
    io: std.Io,
    file: []const u8,
    env: *std.process.Environ.Map,
) !void {
    const l = log(.zoto_edit);
    const is_stdio = std.mem.eql(u8, file, "-");

    const raw = try read_input(gpa, io, file);
    defer gpa.free(raw);

    var zoton_buf: std.Io.Writer.Allocating = .init(gpa);
    defer zoton_buf.deinit();
    try decode_to_zoton(gpa, raw, &zoton_buf.writer);

    var rand_bytes: [8]u8 = undefined;
    try io.randomSecure(&rand_bytes);
    const rand_hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const tmp_path = try gpa.print("/tmp/weft-zoto-{s}.zon", .{rand_hex});
    defer gpa.free(tmp_path);

    {
        const tmp_file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{
            .permissions = domain.read_only_user_permissions,
        });
        defer tmp_file.close(io);
        try tmp_file.writePositionalAll(io, zoton_buf.written(), 0);
    }
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    const editor = env.get("VISUAL") orelse env.get("EDITOR") orelse "vi";
    const shell_cmd = try gpa.print(
        "{s} \"$1\"{s}",
        .{ editor, if (is_stdio) " </dev/tty >/dev/tty" else "" },
    );
    defer gpa.free(shell_cmd);

    while (true) {
        var child = try std.process.spawn(io, .{
            .argv = &.{ "sh", "-c", shell_cmd, "_", tmp_path },
            .stdin = if (is_stdio) .ignore else .inherit,
            .stdout = if (is_stdio) .ignore else .inherit,
            .stderr = .inherit,
            .environ_map = env,
        });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) {
                l.err("editor exited with code {d}", .{code});
                return error.EditorFailed;
            },
            else => {
                l.err("editor terminated abnormally", .{});
                return error.EditorFailed;
            },
        }

        const edited = try std.Io.Dir.cwd().readFileAllocOptions(io, tmp_path, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(edited);

        var encoded: std.Io.Writer.Allocating = .init(gpa);
        defer encoded.deinit();

        encode_from_zoton(
            gpa,
            edited,
            &encoded.writer,
            null,
            null,
        ) catch |err| {
            l.err("failed to encode edited ZOTON: {any}", .{err});
            if (prompt_reopen(io))
                continue
            else
                return err;
        };

        try write_output(io, file, encoded.written());
        return;
    }
}
