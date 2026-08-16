pub const std = @import("std");

pub fn NumPattern(comptime T: type) type {
    return struct {
        patterns: [][]Condition,

        pub const Condition = union(enum) {
            gt: T,
            lt: T,
            eq: T,
            ne: T,
            range: struct {
                start: T,
                step: T = 1,
                stop: T,
            },
        };
        pub fn is_start(ch: T) bool {
            return ch == '>' or ch == '<' or ch == '=' or ch == '!' or ch == '-' or std.ascii.isDigit(ch);
        }
        fn takeNum(str: []const u8, idx: *usize) !T {
            const neg = if (idx.* < str.len and str[idx.*] == '-') blk: {
                idx.* += 1;
                break :blk true;
            } else false;
            const start = idx.*;
            while (idx.* < str.len and @This().isNum(str[idx.*]))
                idx.* += 1;
            const end = idx.*;
            if (start == end)
                return error.NumberExpected;
            const num = try std.fmt.parseInt(T, str[start..end], 10);
            return if (neg)
                0 -| num
            else
                num;
        }
        fn isNum(c: u8) bool {
            return std.ascii.isDigit(c);
        }
        pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
            for (self.patterns) |pattern| {
                alloc.free(pattern);
            }
            alloc.free(self.patterns);
        }
        pub fn matches(self: @This(), val: T) bool {
            for (self.patterns) |pattern| {
                const match = pattern: {
                    for (pattern) |condition| {
                        const cond_match = switch (condition) {
                            .gt => |v| val > v,
                            .lt => |v| val < v,
                            .eq => |v| val == v,
                            .ne => |v| val != v,
                            .range => |r| val >= r.start and val <= r.stop and @rem(val - r.start, r.step) == 0,
                        };
                        if (!cond_match)
                            break :pattern false;
                    }
                    break :pattern true;
                };
                if (match)
                    return true;
            }
            return false;
        }

        pub fn parse(alloc: std.mem.Allocator, str: []const u8) !@This() {
            var patterns: std.ArrayList([]Condition) = .empty;
            defer patterns.deinit(alloc);
            errdefer {
                for (patterns.items) |pattern| {
                    alloc.free(pattern);
                }
            }

            var or_groups = std.mem.splitScalar(u8, str, ',');

            while (or_groups.next()) |group| {
                var pattern: std.ArrayList(Condition) = .empty;
                defer pattern.deinit(alloc);

                var i: usize = 0;
                while (i < group.len) {
                    switch (group[i]) {
                        '>' => {
                            i += 1;
                            try pattern.append(alloc, .{ .gt = try takeNum(group, &i) });
                        },
                        '<' => {
                            i += 1;
                            try pattern.append(alloc, .{ .lt = try takeNum(group, &i) });
                        },
                        '=' => {
                            i += 1;
                            try pattern.append(alloc, .{ .eq = try takeNum(group, &i) });
                        },
                        '!' => {
                            i += 1;
                            try pattern.append(alloc, .{ .ne = try takeNum(group, &i) });
                        },
                        else => if (group[i] == '-' or std.ascii.isDigit(group[i])) {
                            const range_start = i;
                            const start = try takeNum(group, &i);
                            if (i >= group.len or group[i] != ':') {
                                const idx = i -| 1;
                                _ = idx;
                                _ = range_start;
                                return error.SyntaxError;
                            }
                            i += 1;
                            const step = try takeNum(group, &i);
                            if (i < group.len and group[i] == ':') {
                                i += 1;
                                const stop = try takeNum(group, &i);
                                if (stop <= start or step == 0) {
                                    return error.InvalidRange;
                                } else if (@rem(stop - start, step) != 0) {
                                    return error.InvalidRange;
                                } else {
                                    try pattern.append(alloc, .{ .range = .{
                                        .start = start,
                                        .step = step,
                                        .stop = stop,
                                    } });
                                }
                            } else {
                                try pattern.append(alloc, .{ .range = .{
                                    .start = start,
                                    .step = 1,
                                    .stop = step,
                                } });
                            }
                        } else {
                            return error.SyntaxError;
                        },
                    }
                }

                if (pattern.items.len > 0)
                    try patterns.append(alloc, try pattern.toOwnedSlice(alloc));
            }

            return .{
                .patterns = try patterns.toOwnedSlice(alloc),
            };
        }
    };
}
