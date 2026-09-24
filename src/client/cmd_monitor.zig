const std = @import("std");

const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const format_bytes = @import("../util/sizes.zig").format_bytes;
const Monitor = @import("../util/Monitor.zig");
const proto = @import("../domain/proto.zig");
const Remote = @import("Remote.zig");
const Term = @import("../domain/Term.zig");
const zoto = @import("../util/zoto.zig");

fn format_time_only(buf: *[8]u8, ns: i128) []const u8 {
    const epoch_seconds: u64 = if (ns > 0) @intCast(@divTrunc(ns, std.time.ns_per_s)) else 0;
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "00:00:00";
}

fn format_date_only(buf: []u8, ns: i128) []const u8 {
    const epoch_seconds: u64 = if (ns > 0) @intCast(@divTrunc(ns, std.time.ns_per_s)) else 0;
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        @intFromEnum(md.month),
        md.day_index + 1,
    }) catch "----";
}

fn pad_10(buf: *[10]u8, s: []const u8) []const u8 {
    @memset(buf, ' ');
    if (s.len >= 10) {
        @memcpy(buf[0..10], s[0..10]);
    } else {
        const left = (10 - s.len) / 2;
        @memcpy(buf[left .. left + s.len], s);
    }
    return buf;
}

fn format_rate(buf: []u8, rate: u64) []const u8 {
    if (rate == 0) return "0 B/s";
    var b_buf: [32]u8 = undefined;
    const b_str = format_bytes(&b_buf, rate);
    return std.fmt.bufPrint(buf, "{s}/s", .{b_str}) catch "0 B/s";
}

fn render_cell(term: *Term, cell: *const [10]u8, filled: u8, color: Term.Color) void {
    if (!term.is_tty) {
        term.writer().writeAll(cell) catch {};
        return;
    }

    const fill_count = @min(filled, 10);
    if (fill_count > 0) {
        term.setReverse(true);
        term.setColor(color);
        term.writer().writeAll(cell[0..fill_count]) catch {};
        term.setReverse(false);
    }
    if (fill_count < 10) {
        term.setColor(.dim);
        term.writer().writeAll(cell[fill_count..10]) catch {};
        term.setColor(.reset);
    } else {
        term.setColor(.reset);
    }
}

fn render_header(term: *Term, date_str: []const u8) void {
    if (term.is_tty) term.clear_line();
    term.styled(.dim, "─── {s} ──────────────────────────────────────────────────────────────────────────────────────────────────\n", .{date_str});
    if (term.is_tty) term.clear_line();
    term.styled(.bold, "   TIME   ", .{});
    term.print("  ", .{});
    term.styled(.bold, "   CPU    ", .{});
    term.print("  ", .{});
    term.styled(.bold, "   RAM    ", .{});
    term.print("  ", .{});
    term.styled(.bold, "   SWAP   ", .{});
    term.print("  ", .{});
    term.styled(.bold, "   DISK   ", .{});
    term.print("  ", .{});
    term.styled(.bold, "  DISK RX ", .{});
    term.print("  ", .{});
    term.styled(.bold, "  DISK TX ", .{});
    term.print("  ", .{});
    term.styled(.bold, "  NET RX  ", .{});
    term.print("  ", .{});
    term.styled(.bold, "  NET TX  ", .{});
    term.println("", .{});
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
    defer {
        if (term.is_tty and rendered_lines > 0) {
            term.move_up(rendered_lines);
            term.clear_to_end();
            term.flush() catch {};
            rendered_lines = 0;
        }
    }

    var lines_since_header: usize = 0;
    var is_first_sample: bool = true;

    var prev_time_ns: ?i128 = null;
    var prev_cpu: ?u8 = null;
    var prev_ram_used: ?u64 = null;
    var prev_swap_used: ?u64 = null;
    var prev_disk_used: ?u64 = null;
    var prev_disk_r_bytes: ?u64 = null;
    var prev_disk_w_bytes: ?u64 = null;
    var prev_disk_rx_rate: ?u64 = null;
    var prev_disk_tx_rate: ?u64 = null;
    var prev_rx_bytes: ?u64 = null;
    var prev_tx_bytes: ?u64 = null;
    var prev_rx_rate: ?u64 = null;
    var prev_tx_rate: ?u64 = null;

    while (true) {
        var iov = [_][]u8{stream_buf[read_pos..]};
        const n = client.conn.reader.readVec(&iov) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;
        read_pos += n;

        var slice: []const u8 = stream_buf[0..read_pos];
        while (slice.len > 0) {
            var parse_slice = slice;
            const stats = zoto.deserialize(frame_arena.allocator(), &parse_slice, Monitor.Stats, .{ .header = true, .hash = true }) catch |err| {
                if (err == error.BufferTooSmall or err == error.EndOfStream) break;
                term.err("failed to decode stats packet: {any}", .{err});
                return err;
            };

            slice = parse_slice;

            if (term.is_tty and rendered_lines > 0) {
                term.move_up(rendered_lines);
                term.clear_to_end();
                rendered_lines = 0;
            }

            if (is_first_sample) {
                var ram_t_buf: [32]u8 = undefined;
                const ram_t_str = format_bytes(&ram_t_buf, stats.ram.total);
                var ram_a_buf: [32]u8 = undefined;
                const ram_a_str = format_bytes(&ram_a_buf, stats.ram.avail);
                var swp_t_buf: [32]u8 = undefined;
                const swp_t_str = format_bytes(&swp_t_buf, stats.swap.total);
                var disk_t_buf: [32]u8 = undefined;
                const disk_t_str = format_bytes(&disk_t_buf, stats.disk.total);

                if (term.is_tty) term.clear_line();
                term.styled(.bold, "remote: ", .{});
                term.styled(.cyan, "{s}", .{target_remote.get_name()});
                term.styled(.dim, "   cpu: ", .{});
                term.print("{s} ({d}@{d}MHz)", .{ stats.cpu.model, stats.cpu.cores, stats.cpu.freq });
                term.styled(.dim, "   ram: ", .{});
                term.print("{s} (avail {s})", .{ ram_t_str, ram_a_str });
                if (stats.swap.total > 0) {
                    term.styled(.dim, "   swap: ", .{});
                    term.print("{s}", .{swp_t_str});
                }
                term.styled(.dim, "   disk: ", .{});
                term.print("{s}", .{disk_t_str});
                term.println("", .{});
            }

            const term_size = term.get_size();
            const term_height: usize = if (term_size.rows > 0) term_size.rows else 24;
            const effective_height = if (term_height > rendered_lines + 4) term_height - rendered_lines else term_height;
            const header_interval = @max(5, (effective_height * 2) / 3);

            var date_buf: [32]u8 = undefined;
            const date_str = format_date_only(&date_buf, stats.time.nanoseconds);
            if (is_first_sample or lines_since_header >= header_interval) {
                render_header(term, date_str);
                lines_since_header = 0;
            }

            var disk_rx_rate: u64 = 0;
            var disk_tx_rate: u64 = 0;
            var rx_rate: u64 = 0;
            var tx_rate: u64 = 0;
            if (prev_time_ns) |pt| {
                const dt_ns = stats.time.nanoseconds - pt;
                if (dt_ns > 0) {
                    if (prev_disk_r_bytes) |pr| {
                        const d_r = stats.disk.read_bytes -| pr;
                        disk_rx_rate = @intCast(@divTrunc(@as(i128, d_r) * std.time.ns_per_s, dt_ns));
                    }
                    if (prev_disk_w_bytes) |pw| {
                        const d_w = stats.disk.write_bytes -| pw;
                        disk_tx_rate = @intCast(@divTrunc(@as(i128, d_w) * std.time.ns_per_s, dt_ns));
                    }
                    if (prev_rx_bytes) |prx| {
                        const d_rx = stats.net.rx_bytes -| prx;
                        rx_rate = @intCast(@divTrunc(@as(i128, d_rx) * std.time.ns_per_s, dt_ns));
                    }
                    if (prev_tx_bytes) |ptx| {
                        const d_tx = stats.net.tx_bytes -| ptx;
                        tx_rate = @intCast(@divTrunc(@as(i128, d_tx) * std.time.ns_per_s, dt_ns));
                    }
                }
            }

            var time_buf: [8]u8 = undefined;
            const time_str = format_time_only(&time_buf, stats.time.nanoseconds);
            var time_cell: [10]u8 = undefined;
            _ = pad_10(&time_cell, time_str);

            var cpu_raw_buf: [16]u8 = undefined;
            const cpu_raw_str = std.fmt.bufPrint(&cpu_raw_buf, "{d}%", .{stats.cpu.usage}) catch "0%";
            var cpu_cell: [10]u8 = undefined;
            _ = pad_10(&cpu_cell, cpu_raw_str);
            const cpu_filled: u8 = @min(10, @as(u8, @intCast((@as(u16, stats.cpu.usage) * 10 + 50) / 100)));
            const cpu_color: Term.Color = if (prev_cpu) |pc| color_select: {
                const delta: i16 = @as(i16, stats.cpu.usage) - @as(i16, pc);
                if (delta >= 25) {
                    break :color_select .bright_red;
                } else if (delta >= 5) {
                    break :color_select .yellow;
                } else if (delta <= -25) {
                    break :color_select .bright_cyan;
                } else if (delta <= -5) {
                    break :color_select .cyan;
                } else {
                    break :color_select .green;
                }
            } else .green;

            var ram_raw_buf: [32]u8 = undefined;
            const ram_raw_str = format_bytes(&ram_raw_buf, stats.ram.used);
            var ram_cell: [10]u8 = undefined;
            _ = pad_10(&ram_cell, ram_raw_str);
            const ram_pct: u64 = if (stats.ram.total > 0) (stats.ram.used * 100) / stats.ram.total else 0;
            const ram_filled: u8 = @min(10, @as(u8, @intCast((ram_pct * 10 + 50) / 100)));
            const ram_color: Term.Color = if (prev_ram_used) |pr| color_select: {
                if (stats.ram.total > 0) {
                    const delta: i64 = @as(i64, @intCast(stats.ram.used)) - @as(i64, @intCast(pr));
                    const pct_delta = @divTrunc(delta * 100, @as(i64, @intCast(stats.ram.total)));
                    if (pct_delta >= 5) break :color_select .bright_red;
                    if (pct_delta >= 2) break :color_select .yellow;
                    if (pct_delta <= -5) break :color_select .bright_cyan;
                    if (pct_delta <= -2) break :color_select .cyan;
                }
                break :color_select .green;
            } else .green;

            var swap_cell: [10]u8 = undefined;
            var swap_filled: u8 = 0;
            var swap_color: Term.Color = .dim;
            if (stats.swap.total > 0) {
                var swap_raw_buf: [32]u8 = undefined;
                const swap_raw_str = format_bytes(&swap_raw_buf, stats.swap.used);
                _ = pad_10(&swap_cell, swap_raw_str);
                const swap_pct = (stats.swap.used * 100) / stats.swap.total;
                swap_filled = @min(10, @as(u8, @intCast((swap_pct * 10 + 50) / 100)));
                swap_color = if (prev_swap_used) |ps| color_select: {
                    const delta_bytes: i128 = @as(i128, stats.swap.used) - @as(i128, ps);
                    if (delta_bytes >= 50 * 1024 * 1024) {
                        break :color_select .bright_red;
                    } else if (delta_bytes >= 10 * 1024 * 1024) {
                        break :color_select .yellow;
                    } else if (delta_bytes <= -50 * 1024 * 1024) {
                        break :color_select .bright_cyan;
                    } else if (delta_bytes <= -10 * 1024 * 1024) {
                        break :color_select .cyan;
                    } else {
                        break :color_select .green;
                    }
                } else .green;
            } else {
                _ = pad_10(&swap_cell, "-");
            }

            var disk_cell: [10]u8 = undefined;
            var disk_raw_buf: [32]u8 = undefined;
            const disk_raw_str = format_bytes(&disk_raw_buf, stats.disk.used);
            _ = pad_10(&disk_cell, disk_raw_str);
            const disk_pct: u64 = if (stats.disk.total > 0) (stats.disk.used * 100) / stats.disk.total else 0;
            const disk_filled: u8 = @min(10, @as(u8, @intCast((disk_pct * 10 + 50) / 100)));
            const disk_color: Term.Color = if (prev_disk_used) |pd| color_select: {
                const delta: i128 = @as(i128, stats.disk.used) - @as(i128, pd);
                if (delta >= 2 * 1024 * 1024 * 1024) {
                    break :color_select .bright_red;
                } else if (delta >= 500 * 1024 * 1024) {
                    break :color_select .yellow;
                } else if (delta <= -2 * 1024 * 1024 * 1024) {
                    break :color_select .bright_cyan;
                } else if (delta <= -500 * 1024 * 1024) {
                    break :color_select .cyan;
                } else {
                    break :color_select .green;
                }
            } else .green;

            var drx_rate_buf: [32]u8 = undefined;
            const drx_rate_str = format_rate(&drx_rate_buf, disk_rx_rate);
            var drx_cell: [10]u8 = undefined;
            _ = pad_10(&drx_cell, drx_rate_str);
            const drx_filled: u8 = if (disk_rx_rate == 0) 0 else if (disk_rx_rate < 100 * 1024) 1 else if (disk_rx_rate < 500 * 1024) 2 else if (disk_rx_rate < 2 * 1024 * 1024) 3 else if (disk_rx_rate < 10 * 1024 * 1024) 5 else if (disk_rx_rate < 50 * 1024 * 1024) 7 else if (disk_rx_rate < 200 * 1024 * 1024) 9 else 10;
            const drx_color: Term.Color = if (prev_disk_rx_rate) |pdr| color_select: {
                if (disk_rx_rate >= pdr + 10 * 1024 * 1024 and (pdr == 0 or disk_rx_rate >= pdr * 2)) {
                    break :color_select .bright_red;
                } else if (disk_rx_rate > pdr and (disk_rx_rate - pdr) >= 1024 * 1024) {
                    break :color_select .yellow;
                } else if (pdr >= disk_rx_rate + 10 * 1024 * 1024 and (disk_rx_rate == 0 or disk_rx_rate <= pdr / 2)) {
                    break :color_select .bright_cyan;
                } else if (pdr > disk_rx_rate and (pdr - disk_rx_rate) >= 1024 * 1024) {
                    break :color_select .cyan;
                } else if (disk_rx_rate > 0) {
                    break :color_select .green;
                } else {
                    break :color_select .dim;
                }
            } else if (disk_rx_rate > 0) .green else .dim;

            var dtx_rate_buf: [32]u8 = undefined;
            const dtx_rate_str = format_rate(&dtx_rate_buf, disk_tx_rate);
            var dtx_cell: [10]u8 = undefined;
            _ = pad_10(&dtx_cell, dtx_rate_str);
            const dtx_filled: u8 = if (disk_tx_rate == 0) 0 else if (disk_tx_rate < 100 * 1024) 1 else if (disk_tx_rate < 500 * 1024) 2 else if (disk_tx_rate < 2 * 1024 * 1024) 3 else if (disk_tx_rate < 10 * 1024 * 1024) 5 else if (disk_tx_rate < 50 * 1024 * 1024) 7 else if (disk_tx_rate < 200 * 1024 * 1024) 9 else 10;
            const dtx_color: Term.Color = if (prev_disk_tx_rate) |pdt| color_select: {
                if (disk_tx_rate >= pdt + 10 * 1024 * 1024 and (pdt == 0 or disk_tx_rate >= pdt * 2)) {
                    break :color_select .bright_red;
                } else if (disk_tx_rate > pdt and (disk_tx_rate - pdt) >= 1024 * 1024) {
                    break :color_select .yellow;
                } else if (pdt >= disk_tx_rate + 10 * 1024 * 1024 and (disk_tx_rate == 0 or disk_tx_rate <= pdt / 2)) {
                    break :color_select .bright_cyan;
                } else if (pdt > disk_tx_rate and (pdt - disk_tx_rate) >= 1024 * 1024) {
                    break :color_select .cyan;
                } else if (disk_tx_rate > 0) {
                    break :color_select .green;
                } else {
                    break :color_select .dim;
                }
            } else if (disk_tx_rate > 0) .green else .dim;

            var rx_rate_buf: [32]u8 = undefined;
            const rx_rate_str = format_rate(&rx_rate_buf, rx_rate);
            var rx_cell: [10]u8 = undefined;
            _ = pad_10(&rx_cell, rx_rate_str);
            const rx_filled: u8 = if (rx_rate == 0) 0 else if (rx_rate < 5 * 1024) 1 else if (rx_rate < 25 * 1024) 2 else if (rx_rate < 100 * 1024) 3 else if (rx_rate < 500 * 1024) 4 else if (rx_rate < 2 * 1024 * 1024) 5 else if (rx_rate < 10 * 1024 * 1024) 7 else if (rx_rate < 50 * 1024 * 1024) 8 else if (rx_rate < 200 * 1024 * 1024) 9 else 10;
            const rx_color: Term.Color = if (prev_rx_rate) |prx| color_select: {
                if (rx_rate >= prx + 100 * 1024 and (prx == 0 or rx_rate >= prx * 2)) {
                    break :color_select .bright_red;
                } else if (rx_rate > prx and (rx_rate - prx) >= 20 * 1024) {
                    break :color_select .yellow;
                } else if (prx >= rx_rate + 100 * 1024 and (rx_rate == 0 or rx_rate <= prx / 2)) {
                    break :color_select .bright_cyan;
                } else if (prx > rx_rate and (prx - rx_rate) >= 20 * 1024) {
                    break :color_select .cyan;
                } else if (rx_rate > 0) {
                    break :color_select .green;
                } else {
                    break :color_select .dim;
                }
            } else if (rx_rate > 0) .green else .dim;

            var tx_rate_buf: [32]u8 = undefined;
            const tx_rate_str = format_rate(&tx_rate_buf, tx_rate);
            var tx_cell: [10]u8 = undefined;
            _ = pad_10(&tx_cell, tx_rate_str);
            const tx_filled: u8 = if (tx_rate == 0) 0 else if (tx_rate < 5 * 1024) 1 else if (tx_rate < 25 * 1024) 2 else if (tx_rate < 100 * 1024) 3 else if (tx_rate < 500 * 1024) 4 else if (tx_rate < 2 * 1024 * 1024) 5 else if (tx_rate < 10 * 1024 * 1024) 7 else if (tx_rate < 50 * 1024 * 1024) 8 else if (tx_rate < 200 * 1024 * 1024) 9 else 10;
            const tx_color: Term.Color = if (prev_tx_rate) |ptx| color_select: {
                if (tx_rate >= ptx + 100 * 1024 and (ptx == 0 or tx_rate >= ptx * 2)) {
                    break :color_select .bright_red;
                } else if (tx_rate > ptx and (tx_rate - ptx) >= 20 * 1024) {
                    break :color_select .yellow;
                } else if (ptx >= tx_rate + 100 * 1024 and (tx_rate == 0 or tx_rate <= ptx / 2)) {
                    break :color_select .bright_cyan;
                } else if (ptx > tx_rate and (ptx - tx_rate) >= 20 * 1024) {
                    break :color_select .cyan;
                } else if (tx_rate > 0) {
                    break :color_select .green;
                } else {
                    break :color_select .dim;
                }
            } else if (tx_rate > 0) .green else .dim;

            if (term.is_tty) term.clear_line();
            term.styled(.dim, "{s}", .{time_cell});
            term.print("  ", .{});
            render_cell(term, &cpu_cell, cpu_filled, cpu_color);
            term.print("  ", .{});
            render_cell(term, &ram_cell, ram_filled, ram_color);
            term.print("  ", .{});
            render_cell(term, &swap_cell, swap_filled, swap_color);
            term.print("  ", .{});
            render_cell(term, &disk_cell, disk_filled, disk_color);
            term.print("  ", .{});
            render_cell(term, &drx_cell, drx_filled, drx_color);
            term.print("  ", .{});
            render_cell(term, &dtx_cell, dtx_filled, dtx_color);
            term.print("  ", .{});
            render_cell(term, &rx_cell, rx_filled, rx_color);
            term.print("  ", .{});
            render_cell(term, &tx_cell, tx_filled, tx_color);
            term.println("", .{});
            lines_since_header += 1;

            if (term.is_tty) {
                var lines_count: u16 = 0;

                const width: usize = @min(@as(usize, term_size.cols), 106);
                var rule_buf: [256]u8 = undefined;
                const char = "─";
                const count = @max(width, 10);
                var pos: usize = 0;
                for (0..count) |_| {
                    if (pos + char.len <= rule_buf.len) {
                        @memcpy(rule_buf[pos .. pos + char.len], char);
                        pos += char.len;
                    }
                }
                term.clear_line();
                term.styled_ln(.dim, "{s}", .{rule_buf[0..pos]});
                lines_count += 1;

                var ram_u_buf: [32]u8 = undefined;
                var ram_t_buf: [32]u8 = undefined;
                var ram_a_buf: [32]u8 = undefined;
                const ram_u_str = format_bytes(&ram_u_buf, stats.ram.used);
                const ram_t_str = format_bytes(&ram_t_buf, stats.ram.total);
                const ram_a_str = format_bytes(&ram_a_buf, stats.ram.avail);

                var disk_u_buf: [32]u8 = undefined;
                var disk_t_buf: [32]u8 = undefined;
                const disk_u_str = format_bytes(&disk_u_buf, stats.disk.used);
                const disk_t_str = format_bytes(&disk_t_buf, stats.disk.total);

                term.clear_line();
                term.styled(.dim, "cpu: ", .{});
                term.print("{s} ({d}@{d}MHz)", .{ stats.cpu.model, stats.cpu.cores, stats.cpu.freq });
                term.styled(.dim, "   load: ", .{});
                term.print("{d:.2} {d:.2} {d:.2}", .{ stats.load[0], stats.load[1], stats.load[2] });
                if (stats.threads[1] > 0) {
                    term.styled(.dim, " ({d}/{d} threads)", .{ stats.threads[0], stats.threads[1] });
                }
                if (stats.net.tcp_conns > 0) {
                    term.styled(.dim, "   tcp: ", .{});
                    term.print("{d}", .{stats.net.tcp_conns});
                }
                term.println("", .{});
                lines_count += 1;

                term.clear_line();
                term.styled(.dim, "ram: ", .{});
                term.print("{s}/{s} ({d}%, avail {s})", .{ ram_u_str, ram_t_str, ram_pct, ram_a_str });
                if (stats.swap.total > 0) {
                    var swp_u_buf: [32]u8 = undefined;
                    var swp_t_buf: [32]u8 = undefined;
                    const swp_u_str = format_bytes(&swp_u_buf, stats.swap.used);
                    const swp_t_str = format_bytes(&swp_t_buf, stats.swap.total);
                    term.styled(.dim, "   swap: ", .{});
                    term.print("{s}/{s}", .{ swp_u_str, swp_t_str });
                }
                term.styled(.dim, "   disk: ", .{});
                term.print("{s}/{s} ({d}%)", .{ disk_u_str, disk_t_str, disk_pct });
                term.println("", .{});
                lines_count += 1;

                if (stats.services.len == 0) {
                    term.clear_line();
                    term.styled_ln(.dim, "  (no active tasks on {s})", .{target_remote.get_name()});
                    lines_count += 1;
                } else {
                    for (stats.services) |svc| {
                        var mem_buf: [32]u8 = undefined;
                        var peak_buf: [32]u8 = undefined;
                        const mem_str = format_bytes(&mem_buf, svc.memory_bytes);
                        const peak_str = format_bytes(&peak_buf, svc.memory_peak_bytes);
                        const cpu_ms = svc.cpu_usage_usec / 1000;

                        const task_key = try std.fmt.allocPrint(frame_arena.allocator(), "{s}.{s}", .{ svc.task.id.workspace, svc.task.id.pipeline });
                        const color = Term.task_color(task_key);

                        term.clear_line();
                        if (svc.pids > 0) {
                            term.styled_ln(color, "! {s}  (pids: {d}, RAM: {s}, Peak: {s}, CPU: {d}ms)", .{
                                task_key,
                                svc.pids,
                                mem_str,
                                peak_str,
                                cpu_ms,
                            });
                        } else {
                            term.styled_ln(color, "! {s}  (RAM: {s}, Peak: {s}, CPU: {d}ms)", .{
                                task_key,
                                mem_str,
                                peak_str,
                                cpu_ms,
                            });
                        }
                        lines_count += 1;
                    }
                }

                rendered_lines = lines_count;
                term.clear_to_end();
            }

            try term.flush();

            prev_time_ns = stats.time.nanoseconds;
            prev_cpu = stats.cpu.usage;
            prev_ram_used = stats.ram.used;
            prev_swap_used = stats.swap.used;
            prev_disk_used = stats.disk.used;
            prev_disk_r_bytes = stats.disk.read_bytes;
            prev_disk_w_bytes = stats.disk.write_bytes;
            prev_disk_rx_rate = disk_rx_rate;
            prev_disk_tx_rate = disk_tx_rate;
            prev_rx_bytes = stats.net.rx_bytes;
            prev_tx_bytes = stats.net.tx_bytes;
            prev_rx_rate = rx_rate;
            prev_tx_rate = tx_rate;
            is_first_sample = false;

            _ = frame_arena.reset(.retain_capacity);
        }

        if (slice.len > 0) {
            std.mem.copyForwards(u8, stream_buf[0..slice.len], slice);
        }
        read_pos = slice.len;
    }
}
