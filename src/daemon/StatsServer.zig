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

pub fn init(alloc: std.mem.Allocator, io: std.Io, term: *Term) !@This() {
    const history = try alloc.alloc(?Monitor.Stats, 1000);
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
    try self.listeners.append(self.alloc, .{
        .last = timestamp,
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
    const buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
    defer self.alloc.free(buffer);
    const hist_buffer = try self.alloc.alloc(u8, Connection.max_packet_size);
    defer self.alloc.free(hist_buffer);

    while (true) {
        const stats = try self.monitor.fetch(self.alloc, self.io);
        if (self.stats_history[@intCast(self.stats_idx)]) |stat|
            stat.free(self.alloc);
        self.stats_history[@intCast(self.stats_idx)] = stats;
        self.stats_idx = (self.stats_idx + 1) % self.stats_history.len;

        {
            try self.lock.lock(self.io);
            defer self.lock.unlock(self.io);

            var serialized_len: usize = 0;
            var idx: usize = 0;
            while (idx < self.listeners.items.len) {
                const listener = &self.listeners.items[idx];
                const timestamp = listener.last;

                if (serialized_len == 0) {
                    var writer: std.Io.Writer = .fixed(buffer);
                    zoto.serialize(&writer, Monitor.Stats, stats, .{ .header = true }) catch |err| {
                        self.term.err("daemon::stats_server::serialize error: {any}", .{err});
                        break;
                    };
                    serialized_len = writer.buffered().len;
                }

                var send_failed = false;
                if (timestamp.nanoseconds < stats.time.nanoseconds) {
                    var it = StatsIterator.init(self);
                    while (it.next()) |hist_stat| {
                        if (timestamp.nanoseconds != 0 and hist_stat.time.nanoseconds < timestamp.nanoseconds)
                            continue;
                        if (hist_stat.time.nanoseconds >= stats.time.nanoseconds)
                            continue;

                        var hw: std.Io.Writer = .fixed(hist_buffer);
                        zoto.serialize(&hw, Monitor.Stats, hist_stat.*, .{ .header = true }) catch continue;
                        var w_buf: [256]u8 = undefined;
                        var w = listener.stream.writer(self.io, &w_buf);
                        w.interface.writeAll(hw.buffered()) catch {
                            send_failed = true;
                            break;
                        };
                        w.interface.flush() catch {
                            send_failed = true;
                            break;
                        };
                    }
                }

                if (!send_failed and serialized_len > 0) {
                    var w_buf: [256]u8 = undefined;
                    var w = listener.stream.writer(self.io, &w_buf);
                    w.interface.writeAll(buffer[0..serialized_len]) catch {
                        send_failed = true;
                    };
                    if (!send_failed) {
                        w.interface.flush() catch {
                            send_failed = true;
                        };
                    }
                }

                if (send_failed) {
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

test "StatsIterator empty" {
    var history: [5]?Monitor.Stats = .{ null, null, null, null, null };
    const srv: StatsServer = .{
        .listeners = .empty,
        .monitor = .{},
        .alloc = std.testing.allocator,
        .io = undefined,
        .term = undefined,
        .stats_history = &history,
        .stats_idx = 0,
        .lock = .init,
    };
    var it = StatsIterator.init(&srv);
    try std.testing.expect(it.next() == null);
}

test "StatsIterator unwrapped" {
    var stat1: Monitor.Stats = undefined;
    stat1.time = .{ .nanoseconds = 100 };
    var stat2: Monitor.Stats = undefined;
    stat2.time = .{ .nanoseconds = 200 };

    var history: [5]?Monitor.Stats = .{ stat1, stat2, null, null, null };
    const srv: StatsServer = .{
        .listeners = .empty,
        .monitor = .{},
        .alloc = std.testing.allocator,
        .io = undefined,
        .term = undefined,
        .stats_history = &history,
        .stats_idx = 2,
        .lock = .init,
    };
    var it = StatsIterator.init(&srv);
    const s1 = it.next();
    try std.testing.expect(s1 != null);
    try std.testing.expectEqual(s1.?.time.nanoseconds, 100);
    const s2 = it.next();
    try std.testing.expect(s2 != null);
    try std.testing.expectEqual(s2.?.time.nanoseconds, 200);
    try std.testing.expect(it.next() == null);
}

test "StatsIterator wrapped" {
    var stat0: Monitor.Stats = undefined;
    stat0.time = .{ .nanoseconds = 500 };
    var stat1: Monitor.Stats = undefined;
    stat1.time = .{ .nanoseconds = 600 };
    var stat2: Monitor.Stats = undefined;
    stat2.time = .{ .nanoseconds = 200 };
    var stat3: Monitor.Stats = undefined;
    stat3.time = .{ .nanoseconds = 300 };
    var stat4: Monitor.Stats = undefined;
    stat4.time = .{ .nanoseconds = 400 };

    var history: [5]?Monitor.Stats = .{ stat0, stat1, stat2, stat3, stat4 };
    const srv: StatsServer = .{
        .listeners = .empty,
        .monitor = .{},
        .alloc = std.testing.allocator,
        .io = undefined,
        .term = undefined,
        .stats_history = &history,
        .stats_idx = 2,
        .lock = .init,
    };
    var it = StatsIterator.init(&srv);
    const s2 = it.next();
    try std.testing.expect(s2 != null);
    try std.testing.expectEqual(s2.?.time.nanoseconds, 200);
    const s3 = it.next();
    try std.testing.expect(s3 != null);
    try std.testing.expectEqual(s3.?.time.nanoseconds, 300);
    const s4 = it.next();
    try std.testing.expect(s4 != null);
    try std.testing.expectEqual(s4.?.time.nanoseconds, 400);
    const s0 = it.next();
    try std.testing.expect(s0 != null);
    try std.testing.expectEqual(s0.?.time.nanoseconds, 500);
    const s1 = it.next();
    try std.testing.expect(s1 != null);
    try std.testing.expectEqual(s1.?.time.nanoseconds, 600);
    try std.testing.expect(it.next() == null);
}
