const std = @import("std");

const proto = @import("../domain/proto.zig");
const Weft = @import("../domain/Weft.zig");
const Connection = @import("../wire/Connection.zig");
const Packer = @import("../wire/Packer.zig");
const Pressor = @import("../wire/Pressor.zig");
const DeploymentState = @import("DeploymentState.zig");

const Remote = Weft.Remote;

pub fn pull_dir(
    gpa: std.mem.Allocator,
    io: std.Io,
    conn: *Connection,
    task_id: proto.task.Id,
    dir_path: []const u8,
    state: *DeploymentState,
    remote: *const Remote,
    artifact: []const u8,
) !void {
    const conn_buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(conn_buffer);

    try conn.send_object(conn_buffer, proto.Request, .artifact_pull);
    try conn.send_object(
        conn_buffer,
        proto.artifact.pull.Req,
        .{ .header = .{ .id = task_id } },
    );

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);

    var packer: Packer = .unpacker(dir);
    defer packer.deinit(io);
    const pressor_buffer = try gpa.alloc(u8, Pressor.buffer_size);
    defer gpa.free(pressor_buffer);
    var pressor: Pressor = .init(pressor_buffer);
    const decompress_buffer = try gpa.alloc(u8, Pressor.chunk_size);
    defer gpa.free(decompress_buffer);

    var total_files: u32 = 0;
    var received_files: u32 = 0;

    const initial = try conn.recv_object_buf(conn_buffer, proto.artifact.pull.Res);
    switch (initial) {
        .files => |f| total_files = f,
        .footer => {},
    }

    while (true) {
        const data = try conn.recv_buf(conn_buffer);
        if (data.len < 5 or !std.mem.eql(u8, data[0..4], "pack"))
            return error.ExpectedPackHeader;

        switch (data[4]) {
            proto.file => {
                try packer.put(io, .{ .file = data[5..] });
                received_files += 1;
                try state.artifact_progress(
                    io,
                    artifact,
                    remote,
                    .pulling,
                    percentage(received_files, total_files),
                );
            },
            proto.folder => try packer.put(io, .{ .folder = data[5..] }),
            proto.data => try packer.put(io, .{ .data = data[5..] }),
            proto.compressed_data => {
                const compressed = data[5..];
                var input: std.Io.Reader = .fixed(compressed);
                var output: std.Io.Writer = .fixed(decompress_buffer);
                try pressor.decompress(&input, &output);
                try packer.put(io, .{ .data = output.buffered() });
            },
            proto.end => break,
            else => return error.InvalidPack,
        }
    }

    _ = try try conn.recv_object_buf(conn_buffer, proto.Res(proto.artifact.pull.Res));
}

pub fn push_dir(
    gpa: std.mem.Allocator,
    io: std.Io,
    conn: *Connection,
    task_id: proto.task.Id,
    dir_path: []const u8,
    state: *DeploymentState,
    remote: *const Remote,
    artifact: []const u8,
) !void {
    const read_buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(read_buffer);
    const send_buffer = try gpa.alloc(u8, Connection.max_packet_size);
    defer gpa.free(send_buffer);
    const compressed_buffer = try gpa.alloc(u8, Pressor.chunk_size);
    defer gpa.free(compressed_buffer);

    try conn.send_object(send_buffer, proto.Request, .artifact_push);
    try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .header = .{ .id = task_id } });

    const check_res = try conn.recv_object_buf(send_buffer, proto.artifact.push.Res);
    switch (check_res) {
        .has_artifact => |present| if (present) return,
        .footer => {},
    }

    const total_files: u32 = files: {
        var count_dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer count_dir.close(io);
        var count_walker = try count_dir.walk(gpa);
        defer count_walker.deinit();
        var count: u32 = 0;
        while (try count_walker.next(io)) |entry|
            if (entry.kind == .file) {
                count += 1;
            };

        break :files count;
    };

    var artifact_dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer artifact_dir.close(io);

    var packer: Packer = try .packer(gpa, artifact_dir);
    defer packer.deinit(io);
    const pressor_buffer = try gpa.alloc(u8, Pressor.buffer_size);
    defer gpa.free(pressor_buffer);
    var pressor: Pressor = .init(pressor_buffer);

    var sent_files: u32 = 0;
    while (try packer.get(io, read_buffer)) |pack| switch (pack) {
        .file => |path| {
            try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .file = path });
            sent_files += 1;
            try state.artifact_progress(
                io,
                artifact,
                remote,
                .pushing,
                percentage(sent_files, total_files),
            );
        },
        .folder => |path| try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .folder = path }),
        .data => |data| {
            var reader: std.Io.Reader = .fixed(data);
            var writer: std.Io.Writer = .fixed(compressed_buffer);
            if (pressor.compress(&reader, &writer)) |_| {
                if (writer.buffered().len < data.len)
                    try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .data = writer.buffered() })
                else
                    try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .raw = data });
            } else |err| {
                if (err != error.WriteFailed)
                    return err;
                try conn.send_object(send_buffer, proto.artifact.push.Req, .{ .raw = data });
            }
        },
    };
    try conn.send_object(send_buffer, proto.artifact.push.Req, .end);

    const reply = try conn.recv_object_buf(send_buffer, anyerror!proto.artifact.push.Res);
    if (reply) |_| {} else |err| return err;
}

fn percentage(done: u32, total: u32) f32 {
    return if (total > 0)
        @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total))
    else
        1.0;
}
