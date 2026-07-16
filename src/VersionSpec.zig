const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: ?u32 = null,
    patch: ?u32 = null,

    pub fn parse(s: []const u8) !Version {
        var i: usize = 0;
        const major = try parseU32(s, &i);
        if (i >= s.len or s[i] != '.') {
            if (i != s.len) return error.TrailingChars;
            return .{ .major = major };
        }
        i += 1;
        const minor = try parseU32(s, &i);
        if (i >= s.len or s[i] != '.') {
            if (i != s.len) return error.TrailingChars;
            return .{ .major = major, .minor = minor };
        }
        i += 1;
        const patch = try parseU32(s, &i);
        if (i != s.len) return error.TrailingChars;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    fn parseU32(s: []const u8, i: *usize) !u32 {
        const start = i.*;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) i.* += 1;
        if (i.* == start) return error.NumberExpected;
        return std.fmt.parseInt(u32, s[start..i.*], 10);
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        const am = a.minor orelse 0;
        const bm = b.minor orelse 0;
        if (am != bm) return std.math.order(am, bm);
        const ap = a.patch orelse 0;
        const bp = b.patch orelse 0;
        return std.math.order(ap, bp);
    }
};

pub const Operator = enum {
    exact,
    caret,
    tilde,
    gt,
    gte,
    lt,
    lte,
};

pub const VersionSpec = struct {
    op: Operator,
    version: Version,

    pub fn parse(s: []const u8) !VersionSpec {
        if (s.len == 0) return error.Empty;
        var i: usize = 0;
        const op: Operator = switch (s[0]) {
            '^' => blk: {
                i = 1;
                break :blk .caret;
            },
            '~' => blk: {
                i = 1;
                break :blk .tilde;
            },
            '=' => blk: {
                i = 1;
                break :blk .exact;
            },
            '>' => blk: {
                if (s.len > 1 and s[1] == '=') {
                    i = 2;
                    break :blk .gte;
                }
                i = 1;
                break :blk .gt;
            },
            '<' => blk: {
                if (s.len > 1 and s[1] == '=') {
                    i = 2;
                    break :blk .lte;
                }
                i = 1;
                break :blk .lt;
            },
            else => .exact,
        };
        const version = try Version.parse(s[i..]);
        return .{ .op = op, .version = version };
    }

    pub fn satisfies(self: VersionSpec, ver: Version) bool {
        const ord = Version.order(ver, self.version);
        return switch (self.op) {
            .exact => ord == .eq,
            .caret => ver.major == self.version.major and ord != .lt,
            .tilde => ver.major == self.version.major and
                (self.version.minor == null or ver.minor == self.version.minor) and
                ord != .lt,
            .gt => ord == .gt,
            .gte => ord != .lt,
            .lt => ord == .lt,
            .lte => ord != .gt,
        };
    }
};

const testing = std.testing;

test "Version.parse" {
    try testing.expectEqual(Version{ .major = 1 }, try Version.parse("1"));
    try testing.expectEqual(Version{ .major = 1, .minor = 7 }, try Version.parse("1.7"));
    try testing.expectEqual(Version{ .major = 2, .minor = 0, .patch = 1 }, try Version.parse("2.0.1"));
    try testing.expectError(error.NumberExpected, Version.parse(""));
    try testing.expectError(error.TrailingChars, Version.parse("1.7.0.0"));
}

test "VersionSpec.parse" {
    const cs = try VersionSpec.parse("^1.7");
    try testing.expectEqual(Operator.caret, cs.op);
    try testing.expectEqual(@as(u32, 1), cs.version.major);
    try testing.expectEqual(@as(?u32, 7), cs.version.minor);

    const gs = try VersionSpec.parse(">=2.0.0");
    try testing.expectEqual(Operator.gte, gs.op);
}

test "VersionSpec.satisfies - exact" {
    const spec = try VersionSpec.parse("1.7");
    try testing.expect(spec.satisfies(try Version.parse("1.7")));
    try testing.expect(!spec.satisfies(try Version.parse("1.8")));
    try testing.expect(!spec.satisfies(try Version.parse("1.7.1")));
}

test "VersionSpec.satisfies - caret" {
    const spec = try VersionSpec.parse("^1.7");
    try testing.expect(spec.satisfies(try Version.parse("1.7")));
    try testing.expect(spec.satisfies(try Version.parse("1.8")));
    try testing.expect(spec.satisfies(try Version.parse("1.99")));
    try testing.expect(!spec.satisfies(try Version.parse("2.0")));
    try testing.expect(!spec.satisfies(try Version.parse("1.6")));
}

test "VersionSpec.satisfies - tilde" {
    const spec = try VersionSpec.parse("~1.7");
    try testing.expect(spec.satisfies(try Version.parse("1.7")));
    try testing.expect(spec.satisfies(try Version.parse("1.7.5")));
    try testing.expect(!spec.satisfies(try Version.parse("1.8")));
    try testing.expect(!spec.satisfies(try Version.parse("2.0")));
}

test "VersionSpec.satisfies - comparison operators" {
    const gt = try VersionSpec.parse(">1.7");
    try testing.expect(gt.satisfies(try Version.parse("1.8")));
    try testing.expect(!gt.satisfies(try Version.parse("1.7")));

    const lte = try VersionSpec.parse("<=2.0");
    try testing.expect(lte.satisfies(try Version.parse("2.0")));
    try testing.expect(lte.satisfies(try Version.parse("1.9")));
    try testing.expect(!lte.satisfies(try Version.parse("2.1")));
}