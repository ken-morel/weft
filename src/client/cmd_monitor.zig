const std = @import("std");

const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Remote = @import("Remote.zig");
const DaemonInstall = @import("../daemon/DaemonInstall.zig");
const Monitor = @import("../util/Monitor.zig");
const Term = @import("../domain/Term.zig");
const proto = @import("../domain/proto.zig");
const zoto = @import("../util/zoto.zig");
const Connection = @import("../wire/Connection.zig");
const spawn = @import("../domain/spawn.zig").spawn;

const Status = enum {
    connecting,
    connected,
    disconnected,
};

const Sample = struct {
    time: std.Io.Timestamp,
    cpu_pct: f32,
    ram_pct: f32,
    swap_pct: f32,
    prev_cpu: ?f32,
    prev_ram: ?f32,
    prev_swap: ?f32,
    net_rx_rate: f32,
    net_tx_rate: f32,
    disk_r_rate: f32,
    disk_w_rate: f32,
};

const RemoteEntry = struct {
    remote: Remote,
    status: Status = .connecting,
    history: std.ArrayList(Sample) = .empty,
    last_rx: u64 = 0,
    last_tx: u64 = 0,
    last_disk_r: u64 = 0,
    last_disk_w: u64 = 0,
    last_time: ?std.Io.Timestamp = null,
    latest_stats: ?Monitor.Stats = null,
};

const MonitorState = struct {
    entries: []RemoteEntry,
    lock: std.Io.Mutex = .init,
    should_exit: bool = false,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| {
            entry.history.deinit(alloc);
            if (entry.latest_stats) |stat|
                stat.free(alloc);
        }
        alloc.free(self.entries);
    }

    pub fn add_stat(self: *@This(), idx: usize, stat: Monitor.Stats, alloc: std.mem.Allocator, io: std.Io) void {
        self.lock.lock(io) catch return;
        defer self.lock.unlock(io);

        const entry = &self.entries[idx];
        const prev_sample: ?Sample = if (entry.history.items.len > 0)
            entry.history.items[entry.history.items.len - 1]
        else
            null;

        const cpu_pct: f32 = if (stat.cpu.cores.len > 0) blk: {
            var sum: f32 = 0;
            for (stat.cpu.cores) |c|
                sum += @floatCast(c.usage);
            break :blk sum / @as(f32, @floatFromInt(stat.cpu.cores.len));
        } else @floatFromInt(stat.cpu.usage);

        const ram_pct: f32 = if (stat.ram.total > 0)
            @as(f32, @floatFromInt(stat.ram.used)) * 100.0 / @as(f32, @floatFromInt(stat.ram.total))
        else
            0.0;

        const swap_pct: f32 = if (stat.swap.total > 0)
            @as(f32, @floatFromInt(stat.swap.used)) * 100.0 / @as(f32, @floatFromInt(stat.swap.total))
        else
            0.0;

        var cur_rx: u64 = 0;
        var cur_tx: u64 = 0;
        for (stat.net) |n| {
            cur_rx += n.rx_bytes;
            cur_tx += n.tx_bytes;
        }

        var cur_disk_r: u64 = 0;
        var cur_disk_w: u64 = 0;
        for (stat.disk_io) |d| {
            cur_disk_r += d.read;
            cur_disk_w += d.written;
        }

        var net_rx_rate: f32 = 0;
        var net_tx_rate: f32 = 0;
        var disk_r_rate: f32 = 0;
        var disk_w_rate: f32 = 0;

        if (entry.last_time) |last_t| {
            const dt_ns = stat.time.nanoseconds - last_t.nanoseconds;
            if (dt_ns > 100_000_000) {
                const dt_s = @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;
                net_rx_rate = @as(f32, @floatFromInt(cur_rx -| entry.last_rx)) / dt_s;
                net_tx_rate = @as(f32, @floatFromInt(cur_tx -| entry.last_tx)) / dt_s;
                disk_r_rate = @as(f32, @floatFromInt(cur_disk_r -| entry.last_disk_r)) / dt_s;
                disk_w_rate = @as(f32, @floatFromInt(cur_disk_w -| entry.last_disk_w)) / dt_s;
            }
        }

        entry.last_time = stat.time;
        entry.last_rx = cur_rx;
        entry.last_tx = cur_tx;
        entry.last_disk_r = cur_disk_r;
        entry.last_disk_w = cur_disk_w;

        const sample: Sample = .{
            .time = stat.time,
            .cpu_pct = cpu_pct,
            .ram_pct = ram_pct,
            .swap_pct = swap_pct,
            .prev_cpu = if (prev_sample) |p| p.cpu_pct else null,
            .prev_ram = if (prev_sample) |p| p.ram_pct else null,
            .prev_swap = if (prev_sample) |p| p.swap_pct else null,
            .net_rx_rate = net_rx_rate,
            .net_tx_rate = net_tx_rate,
            .disk_r_rate = disk_r_rate,
            .disk_w_rate = disk_w_rate,
        };

        if (entry.history.items.len >= 200)
            _ = entry.history.orderedRemove(0);
        entry.history.append(alloc, sample) catch {};

        if (entry.latest_stats) |old_stat|
            old_stat.free(alloc);
        entry.latest_stats = stat;
    }
};

fn format_bar_number(buf: []u8, value: f32, prev: ?f32, color: bool) []const u8 {
    const clamped = @min(100.0, @max(0.0, value));
    var num_buf: [16]u8 = undefined;
    const s = if (clamped >= 99.95)
        "100.0%"
    else
        std.fmt.bufPrint(&num_buf, "{d:0>5.2}%", .{clamped}) catch " 0.00%";

    if (!color) {
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }

    const num_colored = @min(6, @as(usize, @intFromFloat((clamped / 100.0) * 6.0 + 0.5)));
    const delta = if (prev) |p| value - p else 0.0;

    const bg_code: []const u8 = if (delta > 25.0 or clamped > 90.0)
        "\x1b[41m\x1b[37m\x1b[1m"
    else if (delta > 12.0 or clamped > 75.0)
        "\x1b[43m\x1b[30m\x1b[1m"
    else if (delta > 4.0)
        "\x1b[46m\x1b[30m\x1b[1m"
    else
        "\x1b[42m\x1b[30m\x1b[1m";

    var writer: std.Io.Writer = .fixed(buf);
    if (num_colored > 0) {
        writer.writeAll(bg_code) catch {};
        writer.writeAll(s[0..num_colored]) catch {};
    }
    if (num_colored < s.len) {
        writer.writeAll("\x1b[0m\x1b[2m") catch {};
        writer.writeAll(s[num_colored..]) catch {};
    }
    writer.writeAll("\x1b[0m") catch {};
    return writer.buffered();
}

fn format_rate(buf: []u8, bytes_per_sec: f32) []const u8 {
    if (bytes_per_sec >= 1024.0 * 1024.0 * 1024.0)
        return std.fmt.bufPrint(buf, "{d: >5.1} GB/s", .{bytes_per_sec / (1024.0 * 1024.0 * 1024.0)}) catch "..."
    else if (bytes_per_sec >= 1024.0 * 1024.0)
        return std.fmt.bufPrint(buf, "{d: >5.1} MB/s", .{bytes_per_sec / (1024.0 * 1024.0)}) catch "..."
    else if (bytes_per_sec >= 1024.0)
        return std.fmt.bufPrint(buf, "{d: >5.1} KB/s", .{bytes_per_sec / 1024.0}) catch "..."
    else
        return std.fmt.bufPrint(buf, "{d: >5.1}  B/s", .{bytes_per_sec}) catch "...";
}

fn format_bytes(buf: []u8, bytes: u64) []const u8 {
    const f: f64 = @floatFromInt(bytes);
    if (bytes >= 1024 * 1024 * 1024)
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{f / (1024.0 * 1024.0 * 1024.0)}) catch "..."
    else if (bytes >= 1024 * 1024)
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / (1024.0 * 1024.0)}) catch "..."
    else if (bytes >= 1024)
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / 1024.0}) catch "..."
    else
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "...";
}

fn format_time(buf: []u8, ts: std.Io.Timestamp) []const u8 {
    const secs = @max(0, ts.toSeconds());
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    }) catch "00:00:00";
}

fn monitor_remote_worker(
    alloc: std.mem.Allocator,
    io: std.Io,
    state: *MonitorState,
    remote_idx: usize,
) !void {
    const remote = &state.entries[remote_idx].remote;
    while (!state.should_exit) {
        {
            state.lock.lock(io) catch return;
            state.entries[remote_idx].status = .connecting;
            state.lock.unlock(io);
        }

        const addr = remote.get_address() catch {
            state.lock.lock(io) catch return;
            state.entries[remote_idx].status = .disconnected;
            state.lock.unlock(io);
            std.Io.sleep(io, .fromSeconds(3), .awake) catch return;
            continue;
        };

        const token = remote.get_token() catch {
            state.lock.lock(io) catch return;
            state.entries[remote_idx].status = .disconnected;
            state.lock.unlock(io);
            std.Io.sleep(io, .fromSeconds(3), .awake) catch return;
            continue;
        };

        var client = Client.connect(alloc, io, addr, &token) catch {
            state.lock.lock(io) catch return;
            state.entries[remote_idx].status = .disconnected;
            state.lock.unlock(io);
            std.Io.sleep(io, .fromSeconds(2), .awake) catch return;
            continue;
        };
        defer client.destroy(alloc, io);

        {
            state.lock.lock(io) catch return;
            state.entries[remote_idx].status = .connected;
            state.lock.unlock(io);
        }

        var req_buf: [256]u8 = undefined;
        client.conn.send_object(&req_buf, proto.Request, .system_stats) catch continue;
        client.conn.send_object(&req_buf, proto.system.stats.Req, .{ .from = std.Io.Timestamp.zero }) catch continue;

        const rx_buf = alloc.alloc(u8, 131072) catch return;
        defer alloc.free(rx_buf);
        var rx_len: usize = 0;

        while (!state.should_exit) {
            while (rx_len > 0) {
                var slice: []const u8 = rx_buf[0..rx_len];
                const stat = zoto.deserialize(alloc, &slice, Monitor.Stats, .{ .header = true }) catch |err| {
                    if (err == error.BufferTooSmall)
                        break;
                    break;
                };

                const consumed = rx_len - slice.len;
                std.mem.copyForwards(u8, rx_buf[0..slice.len], rx_buf[consumed..rx_len]);
                rx_len = slice.len;

                state.add_stat(remote_idx, stat, alloc, io);
            }

            const dest = rx_buf[rx_len..];
            if (dest.len == 0) {
                rx_len = 0;
                continue;
            }

            var data: [1][]u8 = .{dest};
            const n = client.rw.@"0".interface.readVec(&data) catch break;
            if (n == 0)
                break;
            rx_len += n;
        }

        state.lock.lock(io) catch return;
        state.entries[remote_idx].status = .disconnected;
        state.lock.unlock(io);
        std.Io.sleep(io, .fromSeconds(2), .awake) catch return;
    }
}

fn render_view(term: *Term, state: *MonitorState, prev_lines: *u16) !void {
    if (!term.is_tty())
        return;

    if (prev_lines.* > 0) {
        term.move_up(prev_lines.*);
        term.clear_to_end();
        prev_lines.* = 0;
    }

    const term_size = term.get_size();
    const rows = term_size.rows;

    var lines: u16 = 0;

    const total_remotes = state.entries.len;
    if (total_remotes == 0)
        return;

    const overhead_per_remote: u16 = 5;
    const available_for_history: u16 = if (rows > total_remotes * overhead_per_remote + 2)
        rows - @as(u16, @intCast(total_remotes)) * overhead_per_remote - 2
    else
        @as(u16, @intCast(total_remotes)) * 3;

    const history_limit = @max(3, available_for_history / @as(u16, @intCast(total_remotes)));

    for (state.entries) |*entry| {
        const name = entry.remote.get_name();
        const addr_str = entry.remote.address.@"0";
        const port = entry.remote.address.@"1";

        const status_str: []const u8 = switch (entry.status) {
            .connected => "\x1b[32mconnected\x1b[0m",
            .connecting => "\x1b[33mconnecting...\x1b[0m",
            .disconnected => "\x1b[31mdisconnected (retrying...)\x1b[0m",
        };

        var cur_cpu_buf: [128]u8 = undefined;
        var cur_ram_buf: [128]u8 = undefined;
        var cur_swap_buf: [128]u8 = undefined;

        const cur_sample = if (entry.history.items.len > 0)
            entry.history.items[entry.history.items.len - 1]
        else
            null;

        const cpu_display = if (cur_sample) |s|
            format_bar_number(&cur_cpu_buf, s.cpu_pct, s.prev_cpu, term.color)
        else
            "--.--%";
        const ram_display = if (cur_sample) |s|
            format_bar_number(&cur_ram_buf, s.ram_pct, s.prev_ram, term.color)
        else
            "--.--%";
        const swap_display = if (cur_sample) |s|
            format_bar_number(&cur_swap_buf, s.swap_pct, s.prev_swap, term.color)
        else
            "--.--%";

        term.println("\x1b[1m── [ {s} ({s}:{d}) ]\x1b[0m  status: {s}  CPU: {s}  RAM: {s}  SWAP: {s}", .{
            name,
            addr_str,
            port,
            status_str,
            cpu_display,
            ram_display,
            swap_display,
        });
        lines += 1;

        term.println("\x1b[2m   TIME       CPU %     RAM %    SWAP %     NET RX     NET TX    DISK R     DISK W\x1b[0m", .{});
        lines += 1;

        const h_len = entry.history.items.len;
        const start_idx = if (h_len > history_limit) h_len - history_limit else 0;

        if (h_len == 0) {
            term.println("   \x1b[2m(waiting for statistics...)\x1b[0m", .{});
            lines += 1;
        } else {
            for (entry.history.items[start_idx..h_len]) |item| {
                var time_buf: [16]u8 = undefined;
                var cpu_buf: [128]u8 = undefined;
                var ram_buf: [128]u8 = undefined;
                var swap_buf: [128]u8 = undefined;
                var rx_buf: [32]u8 = undefined;
                var tx_buf: [32]u8 = undefined;
                var dr_buf: [32]u8 = undefined;
                var dw_buf: [32]u8 = undefined;

                const t_str = format_time(&time_buf, item.time);
                const c_str = format_bar_number(&cpu_buf, item.cpu_pct, item.prev_cpu, term.color);
                const r_str = format_bar_number(&ram_buf, item.ram_pct, item.prev_ram, term.color);
                const sw_str = format_bar_number(&swap_buf, item.swap_pct, item.prev_swap, term.color);
                const rx_str = format_rate(&rx_buf, item.net_rx_rate);
                const tx_str = format_rate(&tx_buf, item.net_tx_rate);
                const dr_str = format_rate(&dr_buf, item.disk_r_rate);
                const dw_str = format_rate(&dw_buf, item.disk_w_rate);

                term.println("   {s}   {s}   {s}   {s}   {s} {s} {s} {s}", .{
                    t_str,
                    c_str,
                    r_str,
                    sw_str,
                    rx_str,
                    tx_str,
                    dr_str,
                    dw_str,
                });
                lines += 1;
            }
        }

        if (entry.latest_stats) |stat| {
            var mem_used_buf: [32]u8 = undefined;
            var mem_tot_buf: [32]u8 = undefined;
            var mem_avail_buf: [32]u8 = undefined;
            const u_str = format_bytes(&mem_used_buf, stat.ram.used);
            const tot_str = format_bytes(&mem_tot_buf, stat.ram.total);
            const av_str = format_bytes(&mem_avail_buf, stat.ram.available);

            if (stat.services.len > 0) {
                term.println("   \x1b[2mRAM: {s}/{s} (avail: {s}) | Tasks ({d}):\x1b[0m", .{ u_str, tot_str, av_str, stat.services.len });
                lines += 1;
                for (stat.services[0..@min(stat.services.len, 3)]) |svc| {
                    var svc_mem_buf: [32]u8 = undefined;
                    const sm_str = format_bytes(&svc_mem_buf, svc.memory_bytes);
                    term.println("     \x1b[36m•\x1b[0m {s} (CPU: {d}ms, RAM: {s})", .{
                        svc.task.id.pipeline,
                        svc.cpu_usage_usec / 1000,
                        sm_str,
                    });
                    lines += 1;
                }
            } else {
                term.println("   \x1b[2mRAM: {s}/{s} (avail: {s}) | CPU: {s} ({d} cores @ {d}MHz)\x1b[0m", .{
                    u_str,
                    tot_str,
                    av_str,
                    stat.cpu.model,
                    stat.cpu.cores.len,
                    stat.cpu.freq,
                });
                lines += 1;
            }
        }
        term.println("", .{});
        lines += 1;
    }

    prev_lines.* = lines;
    try term.flush();
}

pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    installation: ClientInstall,
    maybe_group: ?[]const u8,
) !void {
    const all_remotes = try installation.get_remotes(alloc, io, term);
    var target_remotes: std.ArrayList(Remote) = .empty;
    defer target_remotes.deinit(alloc);

    for (all_remotes) |rem| {
        if (maybe_group) |group| {
            var matches = false;
            if (std.mem.eql(u8, rem.get_name(), group)) {
                matches = true;
            } else {
                for (rem.groups) |g| {
                    if (std.mem.eql(u8, g, group)) {
                        matches = true;
                        break;
                    }
                }
            }
            if (matches)
                try target_remotes.append(alloc, rem);
        } else {
            try target_remotes.append(alloc, rem);
        }
    }

    if (target_remotes.items.len == 0) {
        if (maybe_group) |group| {
            term.err("no remotes found matching group or name '{s}'", .{group});
            return error.RemoteNotFound;
        }

        const config = DaemonInstall.read_config(io, alloc, term) catch null;
        if (config) |cfg| {
            try target_remotes.append(alloc, .{
                .name = "local",
                .address = .{ "127.0.0.1", cfg.port },
                .token = cfg.secret,
                .groups = &.{"local"},
            });
        } else {
            term.err("no remotes configured in remotes.zon and local daemon config not found", .{});
            return error.NoRemotes;
        }
    }

    const entries = try alloc.alloc(RemoteEntry, target_remotes.items.len);
    for (target_remotes.items, 0..) |rem, i| {
        entries[i] = .{
            .remote = rem,
            .status = .connecting,
            .history = .empty,
        };
    }

    var state: MonitorState = .{
        .entries = entries,
    };
    defer state.deinit(alloc);

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    for (entries, 0..) |_, i| {
        spawn(
            io,
            &group,
            monitor_remote_worker,
            .{ alloc, io, &state, i },
        );
    }

    term.hide_cursor();
    defer term.show_cursor();

    var prev_lines: u16 = 0;

    while (true) {
        {
            state.lock.lock(io) catch break;
            defer state.lock.unlock(io);
            try render_view(term, &state, &prev_lines);
        }
        try std.Io.sleep(io, .fromMilliseconds(500), .awake);
    }
}

test "format_bar_number without color" {
    var buf: [64]u8 = undefined;
    const s1 = format_bar_number(&buf, 29.56, null, false);
    try std.testing.expectEqualStrings("29.56%", s1);

    const s2 = format_bar_number(&buf, 0.48, null, false);
    try std.testing.expectEqualStrings("00.48%", s2);

    const s3 = format_bar_number(&buf, 100.0, null, false);
    try std.testing.expectEqualStrings("100.0%", s3);
}

test "format_bar_number with color" {
    var buf: [128]u8 = undefined;
    const s_stable = format_bar_number(&buf, 29.56, 30.0, true);
    try std.testing.expect(s_stable.len > 6);
    try std.testing.expect(std.mem.indexOf(u8, s_stable, "\x1b[42m") != null);

    const s_spike = format_bar_number(&buf, 85.0, 10.0, true);
    try std.testing.expect(s_spike.len > 6);
    try std.testing.expect(std.mem.indexOf(u8, s_spike, "\x1b[41m") != null);
}

test "format_rate and format_bytes" {
    var buf: [32]u8 = undefined;
    const r1 = format_rate(&buf, 500);
    try std.testing.expect(r1.len > 0);

    const r2 = format_rate(&buf, 1024 * 1024 * 2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "MB/s") != null);

    const b1 = format_bytes(&buf, 1024 * 1024 * 500);
    try std.testing.expect(std.mem.indexOf(u8, b1, "MB") != null);
}

