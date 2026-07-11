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
            return std.ascii.isDigit(c) or c == '-';
        }
        pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
            for (self.patterns) |pattern| {
                alloc.free(pattern);
            }
            alloc.free(self.patterns);
        }
        pub fn match(self: @This(), val: T) bool {
            for (self.patterns) |pattern| {
                const matches = pattern: {
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
                if (matches)
                    return true;
            }
            return false;
        }

        pub fn parse(alloc: std.mem.Allocator, str: []const u8) !@This() {
            var patterns: std.ArrayList([]Condition) = .empty;
            defer patterns.deinit(alloc);

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
                        else => if (@This().isNum(group[i])) {
                            const range_start = i;
                            const start = try takeNum(group, &i);
                            if (i >= group.len or group[i] != ':') {
                                const idx = i -| 1;
                                _ = idx;
                                _ = range_start;
                                return error.RangeSyntaxError;
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

const testing = std.testing;

test "NumPattern - unsigned 8-bit complex matching" {
    const alloc = testing.allocator;

    // Pattern:
    // 1. strictly greater than 5 AND strictly less than 10
    // OR 2. exactly equal to 0
    // OR 3. between 10 and 20 (inclusive) stepping by 2
    var pattern = try NumPattern(u8).parse(alloc, ">5<10,=0,10:2:20");
    defer pattern.deinit(alloc);

    // Group 1: >5<10
    try testing.expect(pattern.match(6));
    try testing.expect(pattern.match(9));
    try testing.expect(!pattern.match(5)); // fails >5
    try testing.expect(!pattern.match(11));

    // Group 2: =0
    try testing.expect(pattern.match(0));

    // Group 3: 10:2:20
    try testing.expect(pattern.match(10));
    try testing.expect(pattern.match(12));
    try testing.expect(pattern.match(20));
    try testing.expect(!pattern.match(11)); // wrong step
    try testing.expect(!pattern.match(22)); // out of range
}

test "NumPattern - signed 32-bit negative numbers" {
    const alloc = testing.allocator;

    // Pattern:
    // 1. between -50 and -10 stepping by 10
    // OR 2. greater than -5 AND less than 5
    var pattern = try NumPattern(i32).parse(alloc, "-50:10:-10,>-5<5");
    defer pattern.deinit(alloc);

    // Group 1: -50:10:-10
    try testing.expect(pattern.match(-50));
    try testing.expect(pattern.match(-30));
    try testing.expect(pattern.match(-10));
    try testing.expect(!pattern.match(-45)); // wrong step
    try testing.expect(!pattern.match(-60)); // out of range

    // Group 2: >-5<5
    try testing.expect(pattern.match(-4));
    try testing.expect(pattern.match(0));
    try testing.expect(pattern.match(4));
    try testing.expect(!pattern.match(-5));
    try testing.expect(!pattern.match(5));
}

test "NumPattern - strict memory leak check on multiple parses" {
    const alloc = testing.allocator;

    // Running this in a loop guarantees that if temporary ArrayLists
    // inside the parse() function aren't freed, the test will fail.
    for (0..100) |_| {
        var pattern = try NumPattern(u32).parse(alloc, ">100<500,=1000,50:5:75");

        // Ensure it evaluates correctly
        try testing.expect(pattern.match(250));
        try testing.expect(pattern.match(1000));
        try testing.expect(pattern.match(65));

        // Clean up the arena
        pattern.deinit(alloc);
    }
}

test "NumPattern - error handling" {
    const alloc = testing.allocator;

    // Missing number after operator
    try testing.expectError(error.NumberExpected, NumPattern(u8).parse(alloc, ">"));
    try testing.expectError(error.NumberExpected, NumPattern(u8).parse(alloc, ">5,<"));

    // Malformed range
    try testing.expectError(error.SyntaxError, NumPattern(u8).parse(alloc, "5-10")); // Should be 5:10
}
