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
