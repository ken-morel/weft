const std = @import("std");

const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const Monitor = @import("../util/Monitor.zig");
const zoto = @import("../util/zoto.zig");
const Connection = @import("../wire/Connection.zig");

const StatsServer = @This();

const Listener = struct {
    last: std.Io.Timestamp,
    stream: std.Io.net.Stream,
};

listeners: std.ArrayList(Listener),
monitor: Monitor,
alloc: std.mem.Allocator,
io: std.Io,
term: *Term,
stats_history: []?Monitor.Stats,
stats_idx: u64,
lock: std.Io.Mutex,

pub const StatsIterator = struct {
    stats: []?Monitor.Stats,
    cursor: *const u64,
    idx: u64,
    before: bool,

    pub fn init(srv: *const StatsServer) @This() {
        const is_wrapped = srv.stats_history.len > 0 and srv.stats_history[@intCast(srv.stats_idx)] != null;
        return .{
            .stats = srv.stats_history,
            .cursor = &srv.stats_idx,
            .idx = if (is_wrapped) srv.stats_idx else 0,
            .before = !is_wrapped,
        };
    }

    pub fn next(self: *@This()) ?*const Monitor.Stats {
        if (self.before and self.idx == self.cursor.*)
            return null;
        const stat = &(self.stats[@intCast(self.idx)] orelse return null);
        self.idx += 1;
        if (self.idx >= self.stats.len) {
            self.idx = 0;
            self.before = true;
        }
        return stat;
    }
};

pub const history_capacity: usize = 120;

pub fn init(alloc: std.mem.Allocator, io: std.Io, term: *Term) !@This() {
    const history = try alloc.alloc(?Monitor.Stats, history_capacity);
    @memset(history, null);
    return .{
        .monitor = .{},
        .listeners = .empty,
        .alloc = alloc,
        .io = io,
        .term = term,
        .stats_history = history,
        .stats_idx = 0,
        .lock = .init,
    };
}

pub fn deinit(self: *@This()) void {
    self.monitor.deinit(self.alloc);
    for (self.stats_history) |maybe_stat| {
        if (maybe_stat) |stat|
            stat.free(self.alloc);
    }
    self.alloc.free(self.stats_history);
    for (self.listeners.items) |listener|
        listener.stream.close(self.io);
    self.listeners.deinit(self.alloc);
}

pub fn iterator(self: *const @This()) StatsIterator {
    return StatsIterator.init(self);
}

pub fn add_listener(self: *@This(), stream: std.Io.net.Stream, timestamp: std.Io.Timestamp) !void {
    try self.lock.lock(self.io);
    defer self.lock.unlock(self.io);

    self.term.info("daemon::stats_server new listener connected, catchup from timestamp {d}", .{timestamp.nanoseconds});

    var last_time = timestamp;
    const hist_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
    defer self.alloc.free(hist_buffer);

    var it = StatsIterator.init(self);
    var catchup_count: usize = 0;
    while (it.next()) |hist_stat| {
        if (timestamp.nanoseconds != 0 and hist_stat.time.nanoseconds < timestamp.nanoseconds)
            continue;

        var hw: std.Io.Writer = .fixed(hist_buffer);
        zoto.serialize(&hw, Monitor.Stats, hist_stat.*, .{ .header = true }) catch continue;
        var w_buf: [256]u8 = undefined;
        var w = stream.writer(self.io, &w_buf);
        w.interface.writeAll(hw.buffered()) catch |err| {
            self.term.err("daemon::stats_server send catchup error: {any}", .{err});
            stream.close(self.io);
            return;
        };
        w.interface.flush() catch |err| {
            self.term.err("daemon::stats_server flush catchup error: {any}", .{err});
            stream.close(self.io);
            return;
        };
        last_time = hist_stat.time;
        catchup_count += 1;
    }

    self.term.info("daemon::stats_server sent {d} catchup samples to listener", .{catchup_count});

    if (catchup_count == 0) {
        if (self.monitor.fetch(self.alloc, self.io)) |stats| {
            if (self.stats_history[@intCast(self.stats_idx)]) |stat|
                stat.free(self.alloc);
            self.stats_history[@intCast(self.stats_idx)] = stats;
            self.stats_idx = (self.stats_idx + 1) % self.stats_history.len;

            var hw: std.Io.Writer = .fixed(hist_buffer);
            if (zoto.serialize(&hw, Monitor.Stats, stats, .{ .header = true })) |_| {
                var w_buf: [256]u8 = undefined;
                var w = stream.writer(self.io, &w_buf);
                w.interface.writeAll(hw.buffered()) catch {};
                w.interface.flush() catch {};
                last_time = stats.time;
            } else |_| {}
        } else |err| {
            self.term.err("daemon::stats_server initial fetch error: {any}", .{err});
        }
    }

    try self.listeners.append(self.alloc, .{
        .last = last_time,
        .stream = stream,
    });
}

pub fn run(self: *@This()) error{Canceled}!void {
    while (true) {
        self._run() catch |err| {
            if (err == error.Canceled)
                return error.Canceled
            else {
                self.term.err("daemon::stats_server::run error: {any}", .{err});
                if (@errorReturnTrace()) |trace|
                    std.debug.dumpErrorReturnTrace(trace);
            }
        };
    }
}

fn _run(self: *@This()) !void {
    self.term.info("daemon::stats_server started background sampling loop", .{});
    const buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
    defer self.alloc.free(buffer);

    while (true) {
        const stats = self.monitor.fetch(self.alloc, self.io) catch |err| {
            self.term.err("daemon::stats_server fetch error: {any}", .{err});
            try std.Io.sleep(self.io, .fromSeconds(2), .awake);
            continue;
        };

        {
            try self.lock.lock(self.io);
            defer self.lock.unlock(self.io);

            if (self.stats_history[@intCast(self.stats_idx)]) |stat|
                stat.free(self.alloc);
            self.stats_history[@intCast(self.stats_idx)] = stats;
            self.stats_idx = (self.stats_idx + 1) % self.stats_history.len;

            var serialized_len: usize = 0;
            var idx: usize = 0;
            while (idx < self.listeners.items.len) {
                const listener = &self.listeners.items[idx];

                if (serialized_len == 0) {
                    var writer: std.Io.Writer = .fixed(buffer);
                    zoto.serialize(&writer, Monitor.Stats, stats, .{ .header = true }) catch |err| {
                        self.term.err("daemon::stats_server::serialize error: {any}", .{err});
                        break;
                    };
                    serialized_len = writer.buffered().len;
                }

                var send_failed = false;
                var w_buf: [256]u8 = undefined;
                var w = listener.stream.writer(self.io, &w_buf);
                w.interface.writeAll(buffer[0..serialized_len]) catch |err| {
                    self.term.err("daemon::stats_server send live stat error: {any}", .{err});
                    send_failed = true;
                };
                if (!send_failed) {
                    w.interface.flush() catch |err| {
                        self.term.err("daemon::stats_server flush live stat error: {any}", .{err});
                        send_failed = true;
                    };
                }

                if (send_failed) {
                    self.term.info("daemon::stats_server listener disconnected, removing", .{});
                    listener.stream.close(self.io);
                    _ = self.listeners.swapRemove(idx);
                } else {
                    listener.last = stats.time;
                    idx += 1;
                }
            }
        }

        try std.Io.sleep(self.io, .fromSeconds(2), .awake);
    }
}
