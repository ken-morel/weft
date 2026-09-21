const std = @import("std");

const DaemonInstall = @import("../daemon/DaemonInstall.zig");
const proto = @import("../domain/proto.zig");
const spawn = @import("../domain/spawn.zig").spawn;
const Term = @import("../domain/Term.zig");
const Monitor = @import("../util/Monitor.zig");
const zoto = @import("../util/zoto.zig");
const Connection = @import("../wire/Connection.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Remote = @import("Remote.zig");

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

const TaskInfo = struct {
    workspace: [64]u8,
    workspace_len: usize,
    deployment: [8]u8,
    pipeline: [64]u8,
    pipeline_len: usize,
    cpu_pct: f32,
    cpu_ms: u64,
    cpu_usec: u64,
    mem_bytes: u64,
};

const LatestInfo = struct {
    ram_used: u64,
    ram_total: u64,
    ram_avail: u64,
    cpu_cores: usize,
    cpu_freq: u64,
    cpu_model: [64]u8,
    cpu_model_len: usize,
    tasks_count: usize,
    tasks: [16]TaskInfo,
    tasks_len: usize,
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
    latest_info: ?LatestInfo = null,
};

const MonitorState = struct {
    entries: []RemoteEntry,
    task_filter: ?[]const u8 = null,
    lock: std.Io.Mutex = .init,
    should_exit: bool = false,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.entries) |*entry|
            entry.history.deinit(alloc);
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

        var info: LatestInfo = .{
            .ram_used = stat.ram.used,
            .ram_total = stat.ram.total,
            .ram_avail = stat.ram.available,
            .cpu_cores = stat.cpu.cores.len,
            .cpu_freq = stat.cpu.freq,
            .cpu_model = undefined,
            .cpu_model_len = 0,
            .tasks_count = stat.services.len,
            .tasks = undefined,
            .tasks_len = 0,
        };
        const model_len = @min(stat.cpu.model.len, info.cpu_model.len);
        @memcpy(info.cpu_model[0..model_len], stat.cpu.model[0..model_len]);
        info.cpu_model_len = model_len;

        const max_tasks = @min(stat.services.len, 16);
        for (stat.services[0..max_tasks], 0..) |svc, i| {
            const dep_str = svc.task.id.deployment.to_string();
            var task_cpu_pct: f32 = 0.0;
            if (entry.latest_info) |prev_info| {
                if (entry.last_time) |last_t| {
                    const dt_ns = stat.time.nanoseconds - last_t.nanoseconds;
                    if (dt_ns > 100_000_000) {
                        for (prev_info.tasks[0..prev_info.tasks_len]) |prev_s| {
                            if (std.mem.eql(u8, prev_s.workspace[0..prev_s.workspace_len], svc.task.id.workspace) and
                                std.mem.eql(u8, prev_s.pipeline[0..prev_s.pipeline_len], svc.task.id.pipeline) and
                                std.mem.eql(u8, &prev_s.deployment, &dep_str))
                            {
                                const dt_usec = @divTrunc(dt_ns, 1000);
                                const delta_usec = svc.cpu_usage_usec -| prev_s.cpu_usec;
                                task_cpu_pct = @as(f32, @floatFromInt(delta_usec)) * 100.0 / @as(f32, @floatFromInt(dt_usec));
                                break;
                            }
                        }
                    }
                }
            }

            var t_info: TaskInfo = .{
                .workspace = undefined,
                .workspace_len = 0,
                .deployment = dep_str,
                .pipeline = undefined,
                .pipeline_len = 0,
                .cpu_pct = task_cpu_pct,
                .cpu_ms = svc.cpu_usage_usec / 1000,
                .cpu_usec = svc.cpu_usage_usec,
                .mem_bytes = svc.memory_bytes,
            };
            const ws_len = @min(svc.task.id.workspace.len, t_info.workspace.len);
            @memcpy(t_info.workspace[0..ws_len], svc.task.id.workspace[0..ws_len]);
            t_info.workspace_len = ws_len;

            const pip_len = @min(svc.task.id.pipeline.len, t_info.pipeline.len);
            @memcpy(t_info.pipeline[0..pip_len], svc.task.id.pipeline[0..pip_len]);
            t_info.pipeline_len = pip_len;

            info.tasks[i] = t_info;
        }
        info.tasks_len = max_tasks;
        entry.latest_info = info;

        entry.last_time = stat.time;
        entry.last_rx = cur_rx;
        entry.last_tx = cur_tx;
        entry.last_disk_r = cur_disk_r;
        entry.last_disk_w = cur_disk_w;
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

    const bg_code: []const u8 = if (clamped >= 85.0 or delta >= 50.0)
        "\x1b[41m\x1b[37m\x1b[1m"
    else if (clamped >= 70.0 or delta >= 25.0)
        "\x1b[48;5;208m\x1b[30m\x1b[1m"
    else if (clamped >= 50.0 or delta >= 10.0)
        "\x1b[43m\x1b[30m\x1b[1m"
    else if (delta <= -25.0)
        "\x1b[48;5;24m\x1b[37m\x1b[1m"
    else if (delta <= -10.0)
        "\x1b[48;5;30m\x1b[37m\x1b[1m"
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
                var arena: std.heap.ArenaAllocator = .init(alloc);
                defer arena.deinit();

                var slice: []const u8 = rx_buf[0..rx_len];
                const stat = zoto.deserialize(arena.allocator(), &slice, Monitor.Stats, .{ .header = true }) catch |err| {
                    if (err == error.BufferTooSmall)
                        break;
                    if (std.mem.indexOf(u8, rx_buf[1..rx_len], "ZOTO")) |next_pos| {
                        const skip = next_pos + 1;
                        std.mem.copyForwards(u8, rx_buf[0 .. rx_len - skip], rx_buf[skip..rx_len]);
                        rx_len -= skip;
                        continue;
                    }
                    rx_len = 0;
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

            const buffered_data = client.rw.@"0".interface.buffered();
            if (buffered_data.len > 0) {
                const copy_len = @min(dest.len, buffered_data.len);
                @memcpy(dest[0..copy_len], buffered_data[0..copy_len]);
                client.rw.@"0".interface.toss(copy_len);
                rx_len += copy_len;
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

        term.println("\x1b[1m── [ {s} ({s}:{d}) ]\x1b[0m  status: {s}", .{
            name,
            addr_str,
            port,
            status_str,
        });
        lines += 1;

        term.println("\x1b[2m   TIME       CPU %     RAM %    SWAP %     NET RX     NET TX    DISK R     DISK W\x1b[0m", .{});
        lines += 1;

        const h_len = entry.history.items.len;
        if (h_len == 0) {
            term.println("   \x1b[2m(waiting for statistics...)\x1b[0m", .{});
            lines += 1;
        } else {
            const count = @min(h_len, history_limit);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const item = entry.history.items[h_len - 1 - i];
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

        if (entry.latest_info) |info| {
            var mem_used_buf: [32]u8 = undefined;
            var mem_tot_buf: [32]u8 = undefined;
            var mem_avail_buf: [32]u8 = undefined;
            const u_str = format_bytes(&mem_used_buf, info.ram_used);
            const tot_str = format_bytes(&mem_tot_buf, info.ram_total);
            const av_str = format_bytes(&mem_avail_buf, info.ram_avail);

            if (info.tasks_count > 0) {
                term.println("   \x1b[2mRAM: {s}/{s} (avail: {s}) | Tasks ({d}):\x1b[0m", .{ u_str, tot_str, av_str, info.tasks_count });
                lines += 1;
                for (info.tasks[0..info.tasks_len]) |task| {
                    if (state.task_filter) |filter| {
                        var matches = false;
                        if (std.mem.eql(u8, task.pipeline[0..task.pipeline_len], filter) or
                            std.mem.eql(u8, task.workspace[0..task.workspace_len], filter) or
                            std.mem.eql(u8, &task.deployment, filter))
                        {
                            matches = true;
                        }
                        if (!matches)
                            continue;
                    }
                    var task_mem_buf: [32]u8 = undefined;
                    const sm_str = format_bytes(&task_mem_buf, task.mem_bytes);
                    term.println("     \x1b[36m•\x1b[0m {s} {s} {s} (CPU: {d:.1}% ({d}ms), RAM: {s})", .{
                        task.workspace[0..task.workspace_len],
                        &task.deployment,
                        task.pipeline[0..task.pipeline_len],
                        task.cpu_pct,
                        task.cpu_ms,
                        sm_str,
                    });
                    lines += 1;
                }
                if (info.tasks_count > info.tasks_len and state.task_filter == null) {
                    term.println("     \x1b[2m+ {d} more tasks running...\x1b[0m", .{ info.tasks_count - info.tasks_len });
                    lines += 1;
                }
            } else {
                term.println("   \x1b[2mRAM: {s}/{s} (avail: {s}) | CPU: {s} ({d} cores @ {d}MHz)\x1b[0m", .{
                    u_str,
                    tot_str,
                    av_str,
                    info.cpu_model[0..info.cpu_model_len],
                    info.cpu_cores,
                    info.cpu_freq,
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
    maybe_target: ?[]const u8,
) !void {
    const all_remotes = try installation.get_remotes(alloc, io, term);
    var target_remotes: std.ArrayList(Remote) = .empty;
    defer target_remotes.deinit(alloc);
    var task_filter: ?[]const u8 = null;

    if (maybe_target) |target| {
        for (all_remotes) |rem| {
            if (std.mem.eql(u8, rem.get_name(), target)) {
                try target_remotes.append(alloc, rem);
            } else {
                for (rem.groups) |g| {
                    if (std.mem.eql(u8, g, target)) {
                        try target_remotes.append(alloc, rem);
                        break;
                    }
                }
            }
        }

        if (target_remotes.items.len == 0) {
            for (all_remotes) |rem| {
                const r_name = rem.get_name();
                if (std.mem.startsWith(u8, target, r_name) and target.len > r_name.len and target[r_name.len] == '.') {
                    try target_remotes.append(alloc, rem);
                    task_filter = target[r_name.len + 1 ..];
                    break;
                }
            }
        }

        if (target_remotes.items.len == 0) {
            task_filter = target;
            for (all_remotes) |rem|
                try target_remotes.append(alloc, rem);
        }
    } else {
        for (all_remotes) |rem|
            try target_remotes.append(alloc, rem);
    }

    if (target_remotes.items.len == 0) {
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
        .task_filter = task_filter,
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

    const s_drop = format_bar_number(&buf, 20.0, 50.0, true);
    try std.testing.expect(s_drop.len > 6);
    try std.testing.expect(std.mem.indexOf(u8, s_drop, "\x1b[48;5;24m") != null);
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
