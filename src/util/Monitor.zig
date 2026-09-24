const std = @import("std");

const Task = @import("../daemon/Task.zig");

prev_ticks: ?CpuTicks = null,

pub const Stats = struct {
    pub const Cpu = struct {
        model: []const u8,
        usage: u8,
        freq: u32,
        cores: u16,
    };

    pub const Ram = struct {
        total: u64,
        used: u64,
        avail: u64,
    };

    pub const Swap = struct {
        total: u64,
        used: u64,
    };

    pub const Disk = struct {
        total: u64,
        used: u64,
        read_bytes: u64,
        write_bytes: u64,
    };

    pub const Net = struct {
        rx_bytes: u64,
        tx_bytes: u64,
        tcp_conns: u32,
    };

    pub const Service = struct {
        task: Task,
        cpu_usage_usec: u64,
        memory_bytes: u64,
        memory_peak_bytes: u64,
        pids: u32,
    };

    time: std.Io.Timestamp,
    cpu: Cpu,
    ram: Ram,
    swap: Swap,
    disk: Disk,
    net: Net,
    load: [3]f32,
    threads: [2]u32,
    services: []const Service,

    pub fn free(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.cpu.model);
        for (self.services) |svc|
            svc.task.free_duped(alloc);
        alloc.free(self.services);
    }
};

const CpuTicks = struct {
    user: u64 = 0,
    nice: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,
    iowait: u64 = 0,
    irq: u64 = 0,
    softirq: u64 = 0,
    steal: u64 = 0,

    fn total(self: @This()) u64 {
        return self.user + self.nice + self.system + self.idle + self.iowait + self.irq + self.softirq + self.steal;
    }

    fn busy(self: @This()) u64 {
        return self.user + self.nice + self.system + self.irq + self.softirq + self.steal;
    }

    fn calc_usage(curr: @This(), prev: ?@This()) u8 {
        if (prev) |p| {
            const tot_diff = curr.total() -| p.total();
            const busy_diff = curr.busy() -| p.busy();
            if (tot_diff == 0) return 0;
            return @intCast(@min(100, (busy_diff * 100) / tot_diff));
        }
        const tot = curr.total();
        if (tot == 0) return 0;
        return @intCast(@min(100, (curr.busy() * 100) / tot));
    }
};

pub const Monitor = @This();

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    _ = self;
    _ = alloc;
}

pub fn fetch(self: *@This(), alloc: std.mem.Allocator, io: std.Io) !Stats {
    const time = std.Io.Clock.now(.real, io);
    const cpu = try self.fetch_cpu(alloc, io);
    const ram_swap = fetch_ram_swap(io);
    const disk = fetch_disk(io);
    const net = fetch_net(io);
    const load_thr = fetch_load(io);
    const services = fetch_services(alloc, io) catch &.{};

    return .{
        .time = time,
        .cpu = cpu,
        .ram = ram_swap.ram,
        .swap = ram_swap.swap,
        .disk = disk,
        .net = net,
        .load = load_thr.load,
        .threads = load_thr.threads,
        .services = services,
    };
}

fn fetch_cpu(self: *@This(), alloc: std.mem.Allocator, io: std.Io) !Stats.Cpu {
    var stat_buf: [4096]u8 = undefined;
    const stat_content = read_file(io, "/proc/stat", &stat_buf) orelse "";

    var cur_ticks = CpuTicks{};
    var core_count: u16 = 0;
    var lines = std.mem.splitScalar(u8, stat_content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "cpu ")) {
            var it = std.mem.tokenizeScalar(u8, trimmed[4..], ' ');
            cur_ticks.user = parse_next_u64(&it);
            cur_ticks.nice = parse_next_u64(&it);
            cur_ticks.system = parse_next_u64(&it);
            cur_ticks.idle = parse_next_u64(&it);
            cur_ticks.iowait = parse_next_u64(&it);
            cur_ticks.irq = parse_next_u64(&it);
            cur_ticks.softirq = parse_next_u64(&it);
            cur_ticks.steal = parse_next_u64(&it);
        } else if (std.mem.startsWith(u8, trimmed, "cpu") and trimmed.len > 3 and std.ascii.isDigit(trimmed[3])) {
            core_count += 1;
        }
    }

    const usage = cur_ticks.calc_usage(self.prev_ticks);
    self.prev_ticks = cur_ticks;

    var model_buf: [256]u8 = undefined;
    var model_slice: []const u8 = "Unknown";
    var freq: u32 = 0;

    var cpuinfo_buf: [8192]u8 = undefined;
    if (read_file(io, "/proc/cpuinfo", &cpuinfo_buf)) |cpuinfo| {
        var clines = std.mem.splitScalar(u8, cpuinfo, '\n');
        while (clines.next()) |cline| {
            const trimmed = std.mem.trim(u8, cline, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "model name") and std.mem.eql(u8, model_slice, "Unknown")) {
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |sep| {
                    const val = std.mem.trim(u8, trimmed[sep + 1 ..], " \t");
                    const copy_len = @min(val.len, model_buf.len);
                    @memcpy(model_buf[0..copy_len], val[0..copy_len]);
                    model_slice = model_buf[0..copy_len];
                }
            } else if (std.mem.startsWith(u8, trimmed, "cpu MHz") and freq == 0) {
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |sep| {
                    const val = std.mem.trim(u8, trimmed[sep + 1 ..], " \t");
                    const mhz = std.fmt.parseFloat(f64, val) catch 0;
                    freq = @intFromFloat(mhz);
                }
            }
        }
    }

    if (freq == 0) {
        var freq_buf: [64]u8 = undefined;
        if (read_file(io, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", &freq_buf)) |content| {
            const khz = std.fmt.parseInt(u32, std.mem.trim(u8, content, " \t\r\n"), 10) catch 0;
            freq = khz / 1000;
        }
    }

    return .{
        .model = try alloc.dupe(u8, model_slice),
        .usage = usage,
        .freq = freq,
        .cores = if (core_count > 0) core_count else 1,
    };
}

fn fetch_ram_swap(io: std.Io) struct { ram: Stats.Ram, swap: Stats.Swap } {
    var buf: [4096]u8 = undefined;
    const content = read_file(io, "/proc/meminfo", &buf) orelse "";

    var mem_total: u64 = 0;
    var mem_avail: u64 = 0;
    var mem_free: u64 = 0;
    var swap_total: u64 = 0;
    var swap_free: u64 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            mem_total = parse_meminfo_kb(line) * 1024;
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            mem_avail = parse_meminfo_kb(line) * 1024;
        } else if (std.mem.startsWith(u8, line, "MemFree:")) {
            mem_free = parse_meminfo_kb(line) * 1024;
        } else if (std.mem.startsWith(u8, line, "SwapTotal:")) {
            swap_total = parse_meminfo_kb(line) * 1024;
        } else if (std.mem.startsWith(u8, line, "SwapFree:")) {
            swap_free = parse_meminfo_kb(line) * 1024;
        }
    }

    const ram_used = if (mem_avail > 0 and mem_total >= mem_avail)
        mem_total - mem_avail
    else
        mem_total -| mem_free;

    return .{
        .ram = .{
            .total = mem_total,
            .used = ram_used,
            .avail = if (mem_avail > 0) mem_avail else mem_free,
        },
        .swap = .{
            .total = swap_total,
            .used = swap_total -| swap_free,
        },
    };
}

fn fetch_disk(io: std.Io) Stats.Disk {
    const Statfs = extern struct {
        f_type: isize,
        f_bsize: isize,
        f_blocks: usize,
        f_bfree: usize,
        f_bavail: usize,
        f_files: usize,
        f_ffree: usize,
        f_fsid: [2]i32,
        f_namelen: isize,
        f_frsize: isize,
        f_flags: isize,
        f_spare: [4]isize,
    };

    var st: Statfs = undefined;
    var disk_total: u64 = 0;
    var disk_used: u64 = 0;
    const rc = std.os.linux.syscall2(.statfs, @intFromPtr("/"), @intFromPtr(&st));
    if (rc == 0 and st.f_blocks > 0) {
        const bsize: u64 = @intCast(if (st.f_frsize > 0) st.f_frsize else st.f_bsize);
        disk_total = st.f_blocks * bsize;
        disk_used = disk_total -| (st.f_bfree * bsize);
    }

    var read_bytes: u64 = 0;
    var write_bytes: u64 = 0;
    var ds_buf: [16384]u8 = undefined;
    if (read_file(io, "/proc/diskstats", &ds_buf)) |content| {
        var dlines = std.mem.splitScalar(u8, content, '\n');
        while (dlines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            var it = std.mem.tokenizeAny(u8, trimmed, " \t");
            _ = it.next();
            _ = it.next();
            const dev_name = it.next() orelse continue;
            if (std.mem.startsWith(u8, dev_name, "loop") or std.mem.startsWith(u8, dev_name, "ram"))
                continue;
            _ = it.next();
            _ = it.next();
            const sec_r = parse_next_u64(&it);
            _ = it.next();
            _ = it.next();
            const sec_w = parse_next_u64(&it);
            read_bytes += sec_r * 512;
            write_bytes += sec_w * 512;
        }
    }

    return .{
        .total = disk_total,
        .used = disk_used,
        .read_bytes = read_bytes,
        .write_bytes = write_bytes,
    };
}

fn fetch_net(io: std.Io) Stats.Net {
    var buf: [8192]u8 = undefined;
    const content = read_file(io, "/proc/net/dev", &buf) orelse return .{ .rx_bytes = 0, .tx_bytes = 0, .tcp_conns = 0 };

    var total_rx: u64 = 0;
    var total_tx: u64 = 0;
    var lo_rx: u64 = 0;
    var lo_tx: u64 = 0;
    var has_phys = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '|') != null) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const iface = std.mem.trim(u8, trimmed[0..colon], " \t");
        var it = std.mem.tokenizeAny(u8, trimmed[colon + 1 ..], " \t");
        const rx = parse_next_u64(&it);
        _ = it.next();
        _ = it.next();
        _ = it.next();
        _ = it.next();
        _ = it.next();
        _ = it.next();
        _ = it.next();
        const tx = parse_next_u64(&it);
        if (std.mem.eql(u8, iface, "lo")) {
            lo_rx += rx;
            lo_tx += tx;
        } else {
            total_rx += rx;
            total_tx += tx;
            has_phys = true;
        }
    }

    if (!has_phys) {
        total_rx = lo_rx;
        total_tx = lo_tx;
    }

    const tcp = fetch_tcp(io);

    return .{
        .rx_bytes = total_rx,
        .tx_bytes = total_tx,
        .tcp_conns = tcp,
    };
}

fn fetch_tcp(io: std.Io) u32 {
    var buf: [512]u8 = undefined;
    const content = read_file(io, "/proc/net/sockstat", &buf) orelse return 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "TCP:")) {
            var it = std.mem.tokenizeScalar(u8, trimmed[4..], ' ');
            while (it.next()) |tok| {
                if (std.mem.eql(u8, tok, "inuse")) {
                    const s = it.next() orelse return 0;
                    return std.fmt.parseInt(u32, s, 10) catch 0;
                }
            }
        }
    }
    return 0;
}

fn fetch_load(io: std.Io) struct { load: [3]f32, threads: [2]u32 } {
    var buf: [128]u8 = undefined;
    const content = read_file(io, "/proc/loadavg", &buf) orelse return .{ .load = .{ 0, 0, 0 }, .threads = .{ 0, 0 } };
    var it = std.mem.tokenizeScalar(u8, content, ' ');
    const l1 = it.next() orelse return .{ .load = .{ 0, 0, 0 }, .threads = .{ 0, 0 } };
    const l2 = it.next() orelse return .{ .load = .{ 0, 0, 0 }, .threads = .{ 0, 0 } };
    const l3 = it.next() orelse return .{ .load = .{ 0, 0, 0 }, .threads = .{ 0, 0 } };
    const thr = it.next() orelse "";
    var run: u32 = 0;
    var tot: u32 = 0;
    if (std.mem.indexOfScalar(u8, thr, '/')) |slash| {
        run = std.fmt.parseInt(u32, thr[0..slash], 10) catch 0;
        tot = std.fmt.parseInt(u32, thr[slash + 1 ..], 10) catch 0;
    }
    return .{
        .load = .{
            std.fmt.parseFloat(f32, l1) catch 0,
            std.fmt.parseFloat(f32, l2) catch 0,
            std.fmt.parseFloat(f32, l3) catch 0,
        },
        .threads = .{ run, tot },
    };
}

fn fetch_services(alloc: std.mem.Allocator, io: std.Io) ![]const Stats.Service {
    var cgroup_dir = std.Io.Dir.cwd().openDir(io, "/sys/fs/cgroup/system.slice", .{ .iterate = true }) catch |err|
        if (err == error.FileNotFound)
            std.Io.Dir.cwd().openDir(io, "/sys/fs/cgroup", .{ .iterate = true }) catch return &.{}
        else
            return &.{};
    defer cgroup_dir.close(io);

    var list = std.ArrayListUnmanaged(Stats.Service).empty;
    errdefer list.deinit(alloc);

    var iter = cgroup_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "weft-runner--"))
            continue;

        var unit_name = entry.name;
        if (std.mem.endsWith(u8, unit_name, ".service"))
            unit_name = unit_name[0 .. unit_name.len - ".service".len];

        const t = Task.from_unit_name(unit_name) orelse continue;

        var svc_dir = cgroup_dir.openDir(io, entry.name, .{}) catch continue;
        defer svc_dir.close(io);

        var mem_buf: [64]u8 = undefined;
        var mem_bytes: u64 = 0;
        if (svc_dir.openFile(io, "memory.current", .{ .mode = .read_only })) |f| {
            defer f.close(io);
            const n = f.readPositionalAll(io, &mem_buf, 0) catch 0;
            mem_bytes = std.fmt.parseInt(u64, std.mem.trim(u8, mem_buf[0..n], " \t\r\n"), 10) catch 0;
        } else |_| {}

        var peak_bytes: u64 = 0;
        if (svc_dir.openFile(io, "memory.peak", .{ .mode = .read_only })) |f| {
            defer f.close(io);
            const n = f.readPositionalAll(io, &mem_buf, 0) catch 0;
            peak_bytes = std.fmt.parseInt(u64, std.mem.trim(u8, mem_buf[0..n], " \t\r\n"), 10) catch 0;
        } else |_| {}

        var cpu_stat_buf: [512]u8 = undefined;
        var cpu_usage_usec: u64 = 0;
        if (svc_dir.openFile(io, "cpu.stat", .{ .mode = .read_only })) |f| {
            defer f.close(io);
            const n = f.readPositionalAll(io, &cpu_stat_buf, 0) catch 0;
            var clines = std.mem.splitScalar(u8, cpu_stat_buf[0..n], '\n');
            while (clines.next()) |cline| {
                if (std.mem.startsWith(u8, cline, "usage_usec ")) {
                    var it = std.mem.tokenizeScalar(u8, cline["usage_usec ".len..], ' ');
                    cpu_usage_usec = parse_next_u64(&it);
                }
            }
        } else |_| {}

        var pids: u32 = 0;
        if (svc_dir.openFile(io, "pids.current", .{ .mode = .read_only })) |f| {
            defer f.close(io);
            const n = f.readPositionalAll(io, &mem_buf, 0) catch 0;
            pids = std.fmt.parseInt(u32, std.mem.trim(u8, mem_buf[0..n], " \t\r\n"), 10) catch 0;
        } else |_| {}

        try list.append(alloc, .{
            .task = try t.dupe(alloc),
            .cpu_usage_usec = cpu_usage_usec,
            .memory_bytes = mem_bytes,
            .memory_peak_bytes = peak_bytes,
            .pids = pids,
        });
    }

    return try list.toOwnedSlice(alloc);
}

fn parse_meminfo_kb(line: []const u8) u64 {
    const sep = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    var it = std.mem.tokenizeScalar(u8, line[sep + 1 ..], ' ');
    const num = it.next() orelse return 0;
    return std.fmt.parseInt(u64, num, 10) catch 0;
}

fn parse_next_u64(it: anytype) u64 {
    const s = it.next() orelse return 0;
    return std.fmt.parseInt(u64, s, 10) catch 0;
}

fn read_file(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..n];
}
