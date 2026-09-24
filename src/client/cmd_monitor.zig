const std = @import("std");

const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const format_bytes = @import("../util/sizes.zig").format_bytes;
const Monitor = @import("../util/Monitor.zig");
const proto = @import("../domain/proto.zig");
const Remote = @import("Remote.zig");
const Term = @import("../domain/Term.zig");
const zoto = @import("../util/zoto.zig");

fn format_time(buf: []u8, ns: i128) []const u8 {
    const epoch_seconds: u64 = if (ns > 0) @intCast(@divTrunc(ns, std.time.ns_per_s)) else 0;
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day = epoch.getEpochDay();
    const day_seconds = epoch.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        @intFromEnum(md.month),
        md.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "----";
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    inst: ClientInstall,
    spec: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const remotes = try inst.get_remotes(alloc, io, term);
    if (remotes.len == 0) {
        term.err("no remotes configured. Run 'weft remote install' first.", .{});
        return error.NoRemotes;
    }

    const target_remote: *const Remote = if (spec) |name| remote_find: {
        for (remotes) |*r| {
            if (std.mem.eql(u8, r.get_name(), name))
                break :remote_find r;
        }
        term.err("remote '{s}' not found in remotes.zon", .{name});
        return error.InvalidRemote;
    } else &remotes[0];

    term.info("connecting to remote '{s}' at {s}:{d}...", .{ target_remote.get_name(), target_remote.address.@"0", target_remote.address.@"1" });

    var client = Client.connect(alloc, io, try target_remote.get_address(), &try target_remote.get_token()) catch |err| {
        term.err("failed to connect to daemon on remote '{s}': {any}", .{ target_remote.get_name(), err });
        return err;
    };
    defer client.destroy(alloc, io);

    const req_buf = try alloc.alloc(u8, 256);
    defer alloc.free(req_buf);

    try client.conn.send_object(req_buf, proto.Request, .system_stats);
    try client.conn.send_object(req_buf, proto.system.stats.Req, .{
        .from = .{ .nanoseconds = 0 },
    });

    term.info("connected. Monitoring '{s}' (Ctrl+C to quit)...", .{target_remote.get_name()});

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    var stream_buf = try alloc.alloc(u8, 64 << 10);
    defer alloc.free(stream_buf);

    var read_pos: usize = 0;
    var rendered_lines: u16 = 0;

    const color = term.is_tty;

    while (true) {
        // Read incoming zoto serialized Stats stream from the raw connection reader
        const n = client.conn.reader.readSliceShort(stream_buf[read_pos..]) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;
        read_pos += n;

        var slice: []const u8 = stream_buf[0..read_pos];
        while (slice.len > 0) {
            var parse_slice = slice;
            const stats = zoto.deserialize(frame_arena.allocator(), &parse_slice, Monitor.Stats, .{ .header = true, .hash = true }) catch |err| {
                if (err == error.BufferTooSmall or err == error.EndOfStream) {
                    // Incomplete packet in stream_buf, wait for next read
                    break;
                }
                term.err("failed to decode stats packet: {any}", .{err});
                return err;
            };

            slice = parse_slice;

            // 1. Move up and clear interactive bottom deck if active
            if (term.is_tty and rendered_lines > 0) {
                term.move_up(rendered_lines);
                rendered_lines = 0;
            }

            // 2. Format and print permanent stats log line (scrollback history)
            var time_buf: [32]u8 = undefined;
            const time_str = format_time(&time_buf, stats.time.nanoseconds);

            var ram_u_buf: [32]u8 = undefined;
            var ram_t_buf: [32]u8 = undefined;
            const ram_u_str = format_bytes(&ram_u_buf, stats.ram.used);
            const ram_t_str = format_bytes(&ram_t_buf, stats.ram.total);
            const ram_pct: u64 = if (stats.ram.total > 0) (stats.ram.used * 100) / stats.ram.total else 0;

            if (color) {
                if (stats.swap.total > 0) {
                    var swp_u_buf: [32]u8 = undefined;
                    var swp_t_buf: [32]u8 = undefined;
                    const swp_u_str = format_bytes(&swp_u_buf, stats.swap.used);
                    const swp_t_str = format_bytes(&swp_t_buf, stats.swap.total);
                    term.println("\x1b[2m{s}\x1b[0m \x1b[36mstats\x1b[0m\t\tCPU: {d}%  RAM: {s}/{s} ({d}%)  SWP: {s}/{s}  Tasks: {d}", .{
                        time_str,
                        stats.cpu.usage,
                        ram_u_str,
                        ram_t_str,
                        ram_pct,
                        swp_u_str,
                        swp_t_str,
                        stats.services.len,
                    });
                } else {
                    term.println("\x1b[2m{s}\x1b[0m \x1b[36mstats\x1b[0m\t\tCPU: {d}%  RAM: {s}/{s} ({d}%)  Tasks: {d}", .{
                        time_str,
                        stats.cpu.usage,
                        ram_u_str,
                        ram_t_str,
                        ram_pct,
                        stats.services.len,
                    });
                }
            } else {
                if (stats.swap.total > 0) {
                    var swp_u_buf: [32]u8 = undefined;
                    var swp_t_buf: [32]u8 = undefined;
                    const swp_u_str = format_bytes(&swp_u_buf, stats.swap.used);
                    const swp_t_str = format_bytes(&swp_t_buf, stats.swap.total);
                    term.println("{s} stats\t\tCPU: {d}%  RAM: {s}/{s} ({d}%)  SWP: {s}/{s}  Tasks: {d}", .{
                        time_str,
                        stats.cpu.usage,
                        ram_u_str,
                        ram_t_str,
                        ram_pct,
                        swp_u_str,
                        swp_t_str,
                        stats.services.len,
                    });
                } else {
                    term.println("{s} stats\t\tCPU: {d}%  RAM: {s}/{s} ({d}%)  Tasks: {d}", .{
                        time_str,
                        stats.cpu.usage,
                        ram_u_str,
                        ram_t_str,
                        ram_pct,
                        stats.services.len,
                    });
                }
            }

            // 3. Render interactive pinned bottom deck (only on TTY)
            if (term.is_tty) {
                var lines_count: u16 = 0;

                term.clear_line();
                term.println("\x1b[1;30m--- Active Tasks on {s} ({d}) ---\x1b[0m", .{ target_remote.get_name(), stats.services.len });
                lines_count += 1;

                if (stats.services.len == 0) {
                    term.clear_line();
                    term.println("\x1b[2m  (no active tasks)\x1b[0m", .{});
                    lines_count += 1;
                } else {
                    for (stats.services) |svc| {
                        var mem_buf: [32]u8 = undefined;
                        var peak_buf: [32]u8 = undefined;
                        const mem_str = format_bytes(&mem_buf, svc.memory_bytes);
                        const peak_str = format_bytes(&peak_buf, svc.memory_peak_bytes);
                        const cpu_ms = svc.cpu_usage_usec / 1000;

                        term.clear_line();
                        term.println("! \x1b[1m{s}.{s}\x1b[0m  (RAM: {s}, Peak: {s}, CPU: {d}ms)", .{
                            svc.task.id.workspace,
                            svc.task.id.pipeline,
                            mem_str,
                            peak_str,
                            cpu_ms,
                        });
                        lines_count += 1;
                    }
                }

                rendered_lines = lines_count;
                term.clear_to_end();
            }

            try term.flush();
            _ = frame_arena.reset(.retain_capacity);
        }

        // Shift remaining unparsed bytes to the beginning of stream_buf
        if (slice.len > 0) {
            std.mem.copyForwards(u8, stream_buf[0..slice.len], slice);
        }
        read_pos = slice.len;
    }
}
