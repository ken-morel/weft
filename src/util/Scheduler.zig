const std = @import("std");

const ClosureData = *anyopaque;
const ClosureFn = fn (ClosureData) void;
const Closure = struct { ClosureFn, ClosureData };

const Task = struct {
    closure: Closure,
    start: std.Io.Timestamp,
};
const RunLoop = union(enum) {
    start,
    backlog,
    wait,
    spawn: usize,
};

const spawn_threshold: std.Io.Duration = .fromMilliseconds(500);

const Scheduler = @This();
alloc: std.mem.Allocator,
signal: std.Io.Condition,
todo: std.ArrayList(Task),
clock: std.Io.Clock,

pub fn run(self: *@This(), io: std.Io) !void {
    var backlog: std.ArrayList(Task) = .empty;
    defer backlog.deinit(self.alloc);
    const TaskReturn = union(enum) {
        new: void,
        spawn: void,

        fn new_task(io_: std.Io, self_: *Scheduler) void {
            self_.signal.wait(io_) catch return null;
        }
        fn spawn_task(io_: std.Io, self_: *Scheduler, backlog_: []const Task) void {
            var soonest: ?*Task = null;
            for (backlog_) |*task|
                if (soonest == null or task.start.nanoseconds < soonest.?.start.nanoseconds) {
                    soonest = task;
                };
            const wt: std.Io.Duration = if (soonest) |soon|
                self_.clock.now(io_).durationTo(soon.start)
            else
                .fromSeconds(std.math.maxInt(i64));
            std.Io.sleep(
                io_,
                wt,
                self_.clock,
            );
        }
    };

    run: switch (@as(RunLoop, RunLoop.wait)) {
        .backlog => {
            while (self.todo.pop()) |todo|
                try backlog.append(self.alloc, todo);
            for (backlog.items, 0..) |*item, idx|
                if (item.start.nanoseconds < self.clock.now().addDuration(spawn_threshold))
                    continue :run .{ .spawn = idx };
            continue :run .wait;
        },
        .wait => {
            var ret: [2]TaskReturn = undefined;
            const select: std.Io.Select(TaskReturn) = .init(io, &ret);
            select.concurrent(.new, TaskReturn.new_task, .{self});
            select.concurrent(.spawn, TaskReturn.spawn_task, .{ self, backlog.items });
            try select.await();
            continue :run .backlog;
        },
        .spawn => |idx| {
            const task = backlog.orderedRemove(idx);
            std.Io.async(self.io, task.closure.@"0", .{task.closure.@"1"});
            continue :run .backlog;
        },
    }
}

pub fn schedule(self: *@This(), io: std.Io, func: Closure, in: std.Io.Duration) !void {
    try self.todo.append(self.alloc, .{
        .closure = func,
        .start = self.clock.now().addDuration(in),
    });
    self.signal.broadcast(io);
}
