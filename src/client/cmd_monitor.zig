const std = @import("std");

const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const format_bytes = @import("../util/sizes.zig").format_bytes;
const Monitor = @import("../util/Monitor.zig");
const proto = @import("../domain/proto.zig");
const Remote = @import("Remote.zig");
const Term = @import("../domain/Term.zig");
const zoto = @import("../util/zoto.zig");

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

    term.info("connected. Monitoring system stats (Ctrl+C to quit)...", .{});

    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    var stream_buf = try alloc.alloc(u8, 64 << 10);
    defer alloc.free(stream_buf);

    var read_pos: usize = 0;
    var rendered_lines: u16 = 0;

    while (true) {
        // Read incoming zoto serialized Stats stream from the raw connection reader
        const n = client.conn.reader.readSliceShort(stream_buf[read_pos..]) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (n == 0) break;
        read_pos += n;

        var slice: []const u8 = stream_buf[0..read_pos];
        const stats = zoto.deserialize(frame_arena.allocator(), &slice, Monitor.Stats, .{ .header = true, .hash = true }) catch |err| {
            if (err == error.BufferTooSmall) {
                // Incomplete packet in stream_buf, continue reading next chunk
                continue;
            }
            term.err("failed to decode stats packet: {any}", .{err});
            return err;
        };

        // Shift remaining unparsed bytes to the beginning of stream_buf
        const consumed = read_pos - slice.len;
        if (slice.len > 0) {
            std.mem.copyForwards(u8, stream_buf[0..slice.len], slice);
        }
        read_pos = slice.len;
        _ = consumed;

        // Render dashboard
        if (term.is_tty and rendered_lines > 0) {
            term.move_up(rendered_lines);
            rendered_lines = 0;
        }

        var lines: u16 = 0;

        // Header
        if (term.is_tty) {
            term.println("\x1b[1;36m=== Remote Monitor: {s} ({s}:{d}) ===\x1b[0m", .{ target_remote.get_name(), target_remote.address.@"0", target_remote.address.@"1" });
        } else {
            term.println("=== Remote Monitor: {s} ({s}:{d}) ===", .{ target_remote.get_name(), target_remote.address.@"0", target_remote.address.@"1" });
        }
        lines += 1;

        // CPU
        {
            var bar_buf: [22]u8 = undefined;
            const pct = stats.cpu.usage;
            const filled: usize = @min(20, (pct * 20) / 100);
            @memset(bar_buf[0..filled], '|');
            @memset(bar_buf[filled..20], ' ');
            bar_buf[20] = 0;

            if (term.is_tty) {
                term.println("\x1b[1mCPU:\x1b[0m [{s}] {d}%  ({s}, {d} MHz)", .{ bar_buf[0..20], pct, stats.cpu.model, stats.cpu.freq });
            } else {
                term.println("CPU: [{s}] {d}%  ({s}, {d} MHz)", .{ bar_buf[0..20], pct, stats.cpu.model, stats.cpu.freq });
            }
            lines += 1;

            if (stats.cpu.cores.len > 0) {
                var core_buf: [256]u8 = undefined;
                var cw: std.Io.Writer = .fixed(&core_buf);
                for (stats.cpu.cores, 0..) |core, idx| {
                    if (idx > 0) cw.writeAll("  ") catch break;
                    cw.print("C{d}:{d:.0}%", .{ core.id, core.usage }) catch break;
                    if (idx >= 7 and stats.cpu.cores.len > 8) {
                        cw.print(" ... +{d} more", .{stats.cpu.cores.len - 8}) catch break;
                        break;
                    }
                }
                term.println("     {s}", .{cw.buffered()});
                lines += 1;
            }
        }

        // RAM
        {
            var u_buf: [32]u8 = undefined;
            var t_buf: [32]u8 = undefined;
            var f_buf: [32]u8 = undefined;
            const ram_pct: u64 = if (stats.ram.total > 0) (stats.ram.used * 100) / stats.ram.total else 0;
            const u_str = format_bytes(&u_buf, stats.ram.used);
            const t_str = format_bytes(&t_buf, stats.ram.total);
            const f_str = format_bytes(&f_buf, stats.ram.free);

            if (term.is_tty) {
                term.println("\x1b[1mRAM:\x1b[0m {s} / {s} ({d}%)  [Free: {s}]", .{ u_str, t_str, ram_pct, f_str });
            } else {
                term.println("RAM: {s} / {s} ({d}%)  [Free: {s}]", .{ u_str, t_str, ram_pct, f_str });
            }
            lines += 1;
        }

        // Swap / Zram
        if (stats.swap.total > 0 or stats.zram.total > 0) {
            var su_buf: [32]u8 = undefined;
            var st_buf: [32]u8 = undefined;
            const su_str = format_bytes(&su_buf, stats.swap.used);
            const st_str = format_bytes(&st_buf, stats.swap.total);
            term.println("SWP: {s} / {s}", .{ su_str, st_str });
            lines += 1;
        }

        // Disks
        if (stats.disks.len > 0) {
            if (term.is_tty) {
                term.println("\x1b[1mDisks:\x1b[0m", .{});
            } else {
                term.println("Disks:", .{});
            }
            lines += 1;

            for (stats.disks) |disk| {
                var du_buf: [32]u8 = undefined;
                var dt_buf: [32]u8 = undefined;
                var da_buf: [32]u8 = undefined;
                const du_str = format_bytes(&du_buf, disk.used);
                const dt_str = format_bytes(&dt_buf, disk.total);
                const da_str = format_bytes(&da_buf, disk.available);
                term.println("  {s:<16} {s} / {s} (avail: {s}) [{s}]", .{ disk.mount_point, du_str, dt_str, da_str, disk.fs });
                lines += 1;
            }
        }

        // Active Weft Tasks / Services
        if (stats.services.len > 0) {
            if (term.is_tty) {
                term.println("\x1b[1mRunning Weft Tasks ({d}):\x1b[0m", .{stats.services.len});
            } else {
                term.println("Running Weft Tasks ({d}):", .{stats.services.len});
            }
            lines += 1;

            for (stats.services) |svc| {
                var mem_buf: [32]u8 = undefined;
                var peak_buf: [32]u8 = undefined;
                const mem_str = format_bytes(&mem_buf, svc.memory_bytes);
                const peak_str = format_bytes(&peak_buf, svc.memory_peak_bytes);
                const cpu_sec: f64 = @as(f64, @floatFromInt(svc.cpu_usage_usec)) / 1_000_000.0;
                term.println("  * {s}.{s} (RAM: {s} / peak: {s}, CPU: {d:.2}s)", .{
                    svc.task.id.workspace,
                    svc.task.id.pipeline,
                    mem_str,
                    peak_str,
                    cpu_sec,
                });
                lines += 1;
            }
        }

        rendered_lines = lines;
        if (term.is_tty) {
            term.clear_to_end();
        }
        try term.flush();

        _ = frame_arena.reset(.retain_capacity);
    }
}
