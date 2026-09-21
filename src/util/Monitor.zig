const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const Task = @import("../daemon/Task.zig");
const proto = @import("../domain/proto.zig");

pub const CpuCore = struct {
    id: u16,
    freq: u32,
    usage: f16,
};

pub const Cpu = struct {
    model: []const u8,
    usage: u8,
    freq: u32,
    cores: []const CpuCore,
};

pub const Ram = struct {
    total: u64,
    used: u64,
    free: u64,
    available: u64,
    buffers: u64,
    cached: u64,
};

pub const Swap = struct {
    total: u64,
    used: u64,
    free: u64,
    in_bytes: u64,
    out_bytes: u64,
};

pub const ZramDevice = struct {
    name: []const u8,
    disksize: u64,
    used: u64,
    compressed: u64,
    total: u64,
};

pub const Zram = struct {
    total: u64,
    used: u64,
    compressed: u64,
    devices: []const ZramDevice,
};

pub const DiskMount = struct {
    mount_point: []const u8,
    device: []const u8,
    fs: []const u8,
    total: u64,
    used: u64,
    available: u64,
};

pub const DiskIo = struct {
    device: []const u8,
    read: u64,
    written: u64,
    read_ops: u64,
    write_ops: u64,
    io_time_ms: u64,
};

pub const NetDev = struct {
    interface: []const u8,
    rx_bytes: u64,
    tx_bytes: u64,
    rx_packets: u64,
    tx_packets: u64,
    rx_errors: u64,
    tx_errors: u64,
};

pub const Service = struct {
    task: Task,
    cpu_usage_usec: u64,
    memory_bytes: u64,
    memory_peak_bytes: u64,
    io_read_bytes: u64,
    io_write_bytes: u64,
};

pub const Stats = struct {
    time: std.Io.Timestamp,
    cpu: Cpu,
    ram: Ram,
    swap: Swap,
    zram: Zram,
    disks: []const DiskMount,
    disk_io: []const DiskIo,
    net: []const NetDev,
    services: []const Service,

    pub fn free(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.cpu.model);
        alloc.free(self.cpu.cores);
        for (self.zram.devices) |d|
            alloc.free(d.name);
        alloc.free(self.zram.devices);
        for (self.disks) |d| {
            alloc.free(d.mount_point);
            alloc.free(d.device);
            alloc.free(d.fs);
        }
        alloc.free(self.disks);
        for (self.disk_io) |d|
            alloc.free(d.device);
        alloc.free(self.disk_io);
        for (self.net) |n|
            alloc.free(n.interface);
        alloc.free(self.net);
        for (self.services) |svc|
            svc.task.free_duped(alloc);
        alloc.free(self.services);
    }
};

pub const CoreTicks = struct {
    core_id: u16,
    user: u64 = 0,
    nice: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,
    iowait: u64 = 0,
    irq: u64 = 0,
    softirq: u64 = 0,
    steal: u64 = 0,

    pub fn total(self: @This()) u64 {
        return self.user + self.nice + self.system + self.idle + self.iowait + self.irq + self.softirq + self.steal;
    }

    pub fn busy(self: @This()) u64 {
        return self.user + self.nice + self.system + self.irq + self.softirq + self.steal;
    }

    pub fn calc_usage(curr: @This(), prev: ?@This()) u8 {
        if (prev) |p| {
            const tot_diff = curr.total() -| p.total();
            const busy_diff = curr.busy() -| p.busy();
            if (tot_diff == 0)
                return 0;
            return @intCast(@min(100, (busy_diff * 100) / tot_diff));
        }
        const tot = curr.total();
        if (tot == 0)
            return 0;
        return @intCast(@min(100, (curr.busy() * 100) / tot));
    }
};

prev_total_ticks: ?CoreTicks = null,
prev_core_ticks: std.ArrayListUnmanaged(CoreTicks) = .empty,

pub const Monitor = @This();

pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
    self.prev_core_ticks.deinit(alloc);
}

pub fn fetch(self: *@This(), alloc: std.mem.Allocator, io: std.Io) !Stats {
    const time: std.Io.Timestamp = std.Io.Clock.now(.real, io);

    var cur_total_ticks: ?CoreTicks = null;
    var cur_core_ticks: std.ArrayListUnmanaged(CoreTicks) = .empty;
    defer cur_core_ticks.deinit(alloc);

    const cpu = try self.fetch_cpu(alloc, io, &cur_total_ticks, &cur_core_ticks);
    const ram = fetch_ram(io) catch Ram{
        .total = 0,
        .used = 0,
        .free = 0,
        .available = 0,
        .buffers = 0,
        .cached = 0,
    };
    var swap_zram = fetch_swap_and_zram(alloc, io) catch SwapAndZram{
        .swap = Swap{
            .total = 0,
            .used = 0,
            .free = 0,
            .in_bytes = 0,
            .out_bytes = 0,
        },
        .zram = Zram{
            .total = 0,
            .used = 0,
            .compressed = 0,
            .devices = &.{},
        },
    };
    _ = &swap_zram;

    const disks = fetch_disks(alloc, io) catch &.{};
    const disk_io = fetch_disk_io(alloc, io) catch &.{};
    const net = fetch_net(alloc, io) catch &.{};
    const services = fetch_services(alloc, io) catch &.{};

    if (cur_total_ticks) |tt|
        self.prev_total_ticks = tt;

    if (cur_core_ticks.items.len > 0) {
        self.prev_core_ticks.clearRetainingCapacity();
        try self.prev_core_ticks.appendSlice(alloc, cur_core_ticks.items);
    }

    return .{
        .time = time,
        .cpu = cpu,
        .ram = ram,
        .swap = swap_zram.swap,
        .zram = swap_zram.zram,
        .disks = disks,
        .disk_io = disk_io,
        .net = net,
        .services = services,
    };
}

fn fetch_cpu(
    self: *@This(),
    alloc: std.mem.Allocator,
    io: std.Io,
    out_total: *?CoreTicks,
    out_cores: *std.ArrayListUnmanaged(CoreTicks),
) !Cpu {
    var stat_buf: [32768]u8 = undefined;
    const stat_content = read_file(io, "/proc/stat", &stat_buf) orelse "";

    var model_buf: [256]u8 = undefined;
    var model_slice: []const u8 = "Unknown";
    var mhz_map = std.AutoHashMapUnmanaged(u16, u32).empty;
    defer mhz_map.deinit(alloc);

    var cpuinfo_buf: [32768]u8 = undefined;
    if (read_file(io, "/proc/cpuinfo", &cpuinfo_buf)) |cpuinfo_content| {
        var current_proc: ?u16 = null;
        var lines = std.mem.splitScalar(u8, cpuinfo_content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "model name")) {
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |sep| {
                    const val = std.mem.trim(u8, trimmed[sep + 1 ..], " \t");
                    if (val.len > 0 and std.mem.eql(u8, model_slice, "Unknown")) {
                        const copy_len = @min(val.len, model_buf.len);
                        @memcpy(model_buf[0..copy_len], val[0..copy_len]);
                        model_slice = model_buf[0..copy_len];
                    }
                }
            } else if (std.mem.startsWith(u8, trimmed, "processor")) {
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |sep| {
                    const val = std.mem.trim(u8, trimmed[sep + 1 ..], " \t");
                    current_proc = std.fmt.parseInt(u16, val, 10) catch null;
                }
            } else if (std.mem.startsWith(u8, trimmed, "cpu MHz")) {
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |sep| {
                    const val = std.mem.trim(u8, trimmed[sep + 1 ..], " \t");
                    const mhz_float = std.fmt.parseFloat(f64, val) catch 0;
                    if (current_proc) |p|
                        try mhz_map.put(alloc, p, @intFromFloat(mhz_float));
                }
            }
        }
    }

    var lines = std.mem.splitScalar(u8, stat_content, '\n');
    var core_list = std.ArrayListUnmanaged(CpuCore).empty;
    errdefer core_list.deinit(alloc);

    var total_ticks: ?CoreTicks = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0)
            continue;

        if (std.mem.startsWith(u8, trimmed, "cpu ")) {
            total_ticks = parse_cpu_ticks(trimmed[4..], 0);
        } else if (std.mem.startsWith(u8, trimmed, "cpu") and trimmed.len > 3 and std.ascii.isDigit(trimmed[3])) {
            var it = std.mem.tokenizeScalar(u8, trimmed[3..], ' ');
            const core_id_str = it.next() orelse continue;
            const core_id = std.fmt.parseInt(u16, core_id_str, 10) catch continue;
            const rest = std.mem.trimStart(u8, trimmed[3 + core_id_str.len ..], " ");
            const ticks = parse_cpu_ticks(rest, core_id);
            try out_cores.append(alloc, ticks);

            var prev_ticks: ?CoreTicks = null;
            for (self.prev_core_ticks.items) |pc| {
                if (pc.core_id == core_id) {
                    prev_ticks = pc;
                    break;
                }
            }

            const usage_pct = ticks.calc_usage(prev_ticks);
            const freq = fetch_core_freq(io, core_id) orelse mhz_map.get(core_id) orelse 0;

            try core_list.append(alloc, .{
                .id = core_id,
                .freq = freq,
                .usage = @floatCast(@as(f32, @floatFromInt(usage_pct))),
            });
        }
    }

    out_total.* = total_ticks;

    const total_usage = if (total_ticks) |tt|
        tt.calc_usage(self.prev_total_ticks)
    else
        0;

    var freq_sum: u64 = 0;
    for (core_list.items) |c|
        freq_sum += c.freq;

    const avg_freq: u32 = if (core_list.items.len > 0)
        @intCast(freq_sum / core_list.items.len)
    else
        0;

    const model_duped = try alloc.dupe(u8, model_slice);

    return .{
        .model = model_duped,
        .usage = total_usage,
        .freq = avg_freq,
        .cores = try core_list.toOwnedSlice(alloc),
    };
}

fn parse_cpu_ticks(line: []const u8, core_id: u16) CoreTicks {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    var ticks = CoreTicks{ .core_id = core_id };
    ticks.user = parse_next_u64(&it);
    ticks.nice = parse_next_u64(&it);
    ticks.system = parse_next_u64(&it);
    ticks.idle = parse_next_u64(&it);
    ticks.iowait = parse_next_u64(&it);
    ticks.irq = parse_next_u64(&it);
    ticks.softirq = parse_next_u64(&it);
    ticks.steal = parse_next_u64(&it);
    return ticks;
}

fn parse_next_u64(it: anytype) u64 {
    const s = it.next() orelse return 0;
    return std.fmt.parseInt(u64, s, 10) catch 0;
}

fn fetch_core_freq(io: std.Io, core_id: u16) ?u32 {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/scaling_cur_freq", .{core_id}) catch return null;
    var buf: [64]u8 = undefined;
    const content = read_file(io, path, &buf) orelse return null;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const khz = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    return khz / 1000;
}

fn fetch_ram(io: std.Io) !Ram {
    var buf: [8192]u8 = undefined;
    const content = read_file(io, "/proc/meminfo", &buf) orelse return error.FileNotFound;

    var total: u64 = 0;
    var free: u64 = 0;
    var available: u64 = 0;
    var buffers: u64 = 0;
    var cached: u64 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:"))
            total = parse_meminfo_kb(line) * 1024
        else if (std.mem.startsWith(u8, line, "MemFree:"))
            free = parse_meminfo_kb(line) * 1024
        else if (std.mem.startsWith(u8, line, "MemAvailable:"))
            available = parse_meminfo_kb(line) * 1024
        else if (std.mem.startsWith(u8, line, "Buffers:"))
            buffers = parse_meminfo_kb(line) * 1024
        else if (std.mem.startsWith(u8, line, "Cached:"))
            cached = parse_meminfo_kb(line) * 1024;
    }

    const used = if (available > 0 and total >= available)
        total - available
    else if (total >= (free + buffers + cached))
        total - (free + buffers + cached)
    else
        total -| free;

    return .{
        .total = total,
        .used = used,
        .free = free,
        .available = available,
        .buffers = buffers,
        .cached = cached,
    };
}

fn parse_meminfo_kb(line: []const u8) u64 {
    const sep = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    var it = std.mem.tokenizeScalar(u8, line[sep + 1 ..], ' ');
    const num_str = it.next() orelse return 0;
    return std.fmt.parseInt(u64, num_str, 10) catch 0;
}

const SwapAndZram = struct {
    swap: Swap,
    zram: Zram,
};

fn fetch_swap_and_zram(alloc: std.mem.Allocator, io: std.Io) !SwapAndZram {
    var swaps_buf: [8192]u8 = undefined;
    const swaps_content = read_file(io, "/proc/swaps", &swaps_buf) orelse "";

    var zram_devices = std.ArrayListUnmanaged(ZramDevice).empty;
    errdefer zram_devices.deinit(alloc);

    var swap_total: u64 = 0;
    var swap_used: u64 = 0;
    var zram_total: u64 = 0;
    var zram_used: u64 = 0;
    var zram_compressed: u64 = 0;

    var lines = std.mem.splitScalar(u8, swaps_content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "Filename"))
            continue;

        var it = std.mem.tokenizeAny(u8, trimmed, " \t");
        const filename = it.next() orelse continue;
        _ = it.next();
        const size_kb = parse_next_u64(&it);
        const used_kb = parse_next_u64(&it);

        if (std.mem.startsWith(u8, filename, "/dev/zram")) {
            const dev_name = filename["/dev/".len..];
            const stat = fetch_zram_stats(io, dev_name);
            const disksize = if (stat.disksize > 0) stat.disksize else size_kb * 1024;
            const orig_size = if (stat.orig_size > 0) stat.orig_size else used_kb * 1024;
            const compr_size = stat.compr_size;
            const mem_used = if (stat.mem_used > 0) stat.mem_used else used_kb * 1024;
            _ = orig_size;

            try zram_devices.append(alloc, .{
                .name = try alloc.dupe(u8, dev_name),
                .disksize = disksize,
                .used = mem_used,
                .compressed = compr_size,
                .total = disksize,
            });

            zram_total += disksize;
            zram_used += mem_used;
            zram_compressed += compr_size;
        } else {
            swap_total += size_kb * 1024;
            swap_used += used_kb * 1024;
        }
    }

    var in_bytes: u64 = 0;
    var out_bytes: u64 = 0;
    var vmstat_buf: [8192]u8 = undefined;
    if (read_file(io, "/proc/vmstat", &vmstat_buf)) |vmstat_content| {
        var vlines = std.mem.splitScalar(u8, vmstat_content, '\n');
        while (vlines.next()) |line| {
            if (std.mem.startsWith(u8, line, "pswpin ")) {
                var it = std.mem.tokenizeScalar(u8, line["pswpin ".len..], ' ');
                in_bytes = parse_next_u64(&it) * 4096;
            } else if (std.mem.startsWith(u8, line, "pswpout ")) {
                var it = std.mem.tokenizeScalar(u8, line["pswpout ".len..], ' ');
                out_bytes = parse_next_u64(&it) * 4096;
            }
        }
    }

    const swap_free = swap_total -| swap_used;

    return .{
        .swap = .{
            .total = swap_total,
            .used = swap_used,
            .free = swap_free,
            .in_bytes = in_bytes,
            .out_bytes = out_bytes,
        },
        .zram = .{
            .total = zram_total,
            .used = zram_used,
            .compressed = zram_compressed,
            .devices = try zram_devices.toOwnedSlice(alloc),
        },
    };
}

const ZramSysStat = struct {
    disksize: u64 = 0,
    orig_size: u64 = 0,
    compr_size: u64 = 0,
    mem_used: u64 = 0,
};

fn fetch_zram_stats(io: std.Io, dev_name: []const u8) ZramSysStat {
    var res = ZramSysStat{};
    var path_buf: [128]u8 = undefined;

    if (std.fmt.bufPrint(&path_buf, "/sys/block/{s}/disksize", .{dev_name})) |path| {
        var b: [64]u8 = undefined;
        if (read_file(io, path, &b)) |content| {
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            res.disksize = std.fmt.parseInt(u64, trimmed, 10) catch 0;
        }
    } else |_| {}

    if (std.fmt.bufPrint(&path_buf, "/sys/block/{s}/mm_stat", .{dev_name})) |path| {
        var b: [256]u8 = undefined;
        if (read_file(io, path, &b)) |content| {
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            var it = std.mem.tokenizeAny(u8, trimmed, " \t");
            res.orig_size = parse_next_u64(&it);
            res.compr_size = parse_next_u64(&it);
            res.mem_used = parse_next_u64(&it);
        }
    } else |_| {}

    return res;
}

fn fetch_disks(alloc: std.mem.Allocator, io: std.Io) ![]const DiskMount {
    var buf: [16384]u8 = undefined;
    const content = read_file(io, "/proc/mounts", &buf) orelse return &.{};

    var list = std.ArrayListUnmanaged(DiskMount).empty;
    errdefer list.deinit(alloc);

    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(alloc);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0)
            continue;

        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        const dev = it.next() orelse continue;
        const mount_point = it.next() orelse continue;
        const fs_type = it.next() orelse continue;

        if (!std.mem.startsWith(u8, dev, "/dev/"))
            continue;
        if (std.mem.startsWith(u8, fs_type, "tmpfs") or std.mem.startsWith(u8, fs_type, "devtmpfs"))
            continue;
        if (seen.contains(mount_point))
            continue;

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
        const null_path = try alloc.dupeZ(u8, mount_point);
        defer alloc.free(null_path);

        const rc = std.os.linux.syscall2(.statfs, @intFromPtr(null_path.ptr), @intFromPtr(&st));
        if (rc != 0 or st.f_blocks == 0)
            continue;

        try seen.put(alloc, mount_point, {});

        const bsize: u64 = @intCast(if (st.f_frsize > 0) st.f_frsize else st.f_bsize);
        const total_bytes: u64 = st.f_blocks * bsize;
        const free_bytes: u64 = st.f_bfree * bsize;
        const avail_bytes: u64 = st.f_bavail * bsize;
        const used_bytes: u64 = total_bytes -| free_bytes;

        try list.append(alloc, .{
            .mount_point = try alloc.dupe(u8, mount_point),
            .device = try alloc.dupe(u8, dev),
            .fs = try alloc.dupe(u8, fs_type),
            .total = total_bytes,
            .used = used_bytes,
            .available = avail_bytes,
        });
    }

    return try list.toOwnedSlice(alloc);
}

fn fetch_disk_io(alloc: std.mem.Allocator, io: std.Io) ![]const DiskIo {
    var buf: [32768]u8 = undefined;
    const content = read_file(io, "/proc/diskstats", &buf) orelse return &.{};

    var list = std.ArrayListUnmanaged(DiskIo).empty;
    errdefer list.deinit(alloc);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0)
            continue;

        var it = std.mem.tokenizeAny(u8, trimmed, " \t");
        _ = it.next();
        _ = it.next();
        const dev_name = it.next() orelse continue;

        if (std.mem.startsWith(u8, dev_name, "loop") or std.mem.startsWith(u8, dev_name, "ram"))
            continue;

        var sys_block_buf: [128]u8 = undefined;
        const sys_block_path = std.fmt.bufPrint(&sys_block_buf, "/sys/block/{s}", .{dev_name}) catch continue;
        var block_dir = std.Io.Dir.cwd().openDir(io, sys_block_path, .{}) catch continue;
        block_dir.close(io);

        const reads_completed = parse_next_u64(&it);
        _ = it.next();
        const sectors_read = parse_next_u64(&it);
        _ = it.next();
        const writes_completed = parse_next_u64(&it);
        _ = it.next();
        const sectors_written = parse_next_u64(&it);
        _ = it.next();
        _ = it.next();
        const time_io = parse_next_u64(&it);

        try list.append(alloc, .{
            .device = try alloc.dupe(u8, dev_name),
            .read = sectors_read * 512,
            .written = sectors_written * 512,
            .read_ops = reads_completed,
            .write_ops = writes_completed,
            .io_time_ms = time_io,
        });
    }

    return try list.toOwnedSlice(alloc);
}

fn fetch_net(alloc: std.mem.Allocator, io: std.Io) ![]const NetDev {
    var buf: [16384]u8 = undefined;
    const content = read_file(io, "/proc/net/dev", &buf) orelse return &.{};

    var list = std.ArrayListUnmanaged(NetDev).empty;
    errdefer list.deinit(alloc);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '|') != null)
            continue;

        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const iface = std.mem.trim(u8, trimmed[0..colon], " \t");
        const rest = trimmed[colon + 1 ..];

        var it = std.mem.tokenizeAny(u8, rest, " \t");
        const rx_bytes = parse_next_u64(&it);
        const rx_packets = parse_next_u64(&it);
        const rx_errs = parse_next_u64(&it);
        _ = it.next();
        _ = it.next();
        _ = it.next();
        _ = it.next();
        _ = it.next();
        const tx_bytes = parse_next_u64(&it);
        const tx_packets = parse_next_u64(&it);
        const tx_errs = parse_next_u64(&it);

        try list.append(alloc, .{
            .interface = try alloc.dupe(u8, iface),
            .rx_bytes = rx_bytes,
            .tx_bytes = tx_bytes,
            .rx_packets = rx_packets,
            .tx_packets = tx_packets,
            .rx_errors = rx_errs,
            .tx_errors = tx_errs,
        });
    }

    return try list.toOwnedSlice(alloc);
}

fn fetch_services(alloc: std.mem.Allocator, io: std.Io) ![]const Service {
    var cgroup_dir = std.Io.Dir.cwd().openDir(io, "/sys/fs/cgroup/system.slice", .{ .iterate = true }) catch |err|
        if (err == error.FileNotFound)
            std.Io.Dir.cwd().openDir(io, "/sys/fs/cgroup", .{ .iterate = true }) catch return &.{}
        else
            return &.{};
    defer cgroup_dir.close(io);

    var list = std.ArrayListUnmanaged(Service).empty;
    errdefer list.deinit(alloc);

    var iter = cgroup_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory)
            continue;

        if (!std.mem.startsWith(u8, entry.name, "weft-runner--"))
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
            const s = std.mem.trim(u8, mem_buf[0..n], " \t\r\n");
            mem_bytes = std.fmt.parseInt(u64, s, 10) catch 0;
        } else |_| {}

        var peak_bytes: u64 = 0;
        if (svc_dir.openFile(io, "memory.peak", .{ .mode = .read_only })) |f| {
            defer f.close(io);
            const n = f.readPositionalAll(io, &mem_buf, 0) catch 0;
            const s = std.mem.trim(u8, mem_buf[0..n], " \t\r\n");
            peak_bytes = std.fmt.parseInt(u64, s, 10) catch 0;
        } else |_| {}

        var cpu_stat_buf: [1024]u8 = undefined;
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

        var io_stat_buf: [1024]u8 = undefined;
        var io_read_bytes: u64 = 0;
        var io_write_bytes: u64 = 0;
        if (svc_dir.openFile(io, "io.stat", .{ .mode = .read_only })) |f| {
            defer f.close(io);
            const n = f.readPositionalAll(io, &io_stat_buf, 0) catch 0;
            var iolines = std.mem.splitScalar(u8, io_stat_buf[0..n], '\n');
            while (iolines.next()) |ioline| {
                var it = std.mem.tokenizeScalar(u8, ioline, ' ');
                while (it.next()) |tok| {
                    if (std.mem.startsWith(u8, tok, "rbytes="))
                        io_read_bytes += std.fmt.parseInt(u64, tok["rbytes=".len..], 10) catch 0
                    else if (std.mem.startsWith(u8, tok, "wbytes="))
                        io_write_bytes += std.fmt.parseInt(u64, tok["wbytes=".len..], 10) catch 0;
                }
            }
        } else |_| {}

        try list.append(alloc, .{
            .task = try t.dupe(alloc),
            .cpu_usage_usec = cpu_usage_usec,
            .memory_bytes = mem_bytes,
            .memory_peak_bytes = peak_bytes,
            .io_read_bytes = io_read_bytes,
            .io_write_bytes = io_write_bytes,
        });
    }

    return try list.toOwnedSlice(alloc);
}

fn read_file(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..n];
}

var global_monitor: Monitor = .{};

pub fn fetch_stats(alloc: std.mem.Allocator, io: std.Io) !Stats {
    return global_monitor.fetch(alloc, io);
}

test "fetch_stats" {
    var mon = Monitor{};
    defer mon.deinit(std.testing.allocator);

    const s1 = try mon.fetch(std.testing.allocator, std.testing.io);
    defer s1.free(std.testing.allocator);

    try std.testing.expect(s1.cpu.cores.len > 0);
    try std.testing.expect(s1.ram.total > 0);
    try std.testing.expect(s1.disks.len > 0);
}
