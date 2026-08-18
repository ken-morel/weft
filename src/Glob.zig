const std = @import("std");

pattern: []const u8,
negated: bool,
only_dir: bool,
anchored: bool,
base_dir: ?[]const u8,

pub fn parse(raw: []const u8, base_dir: ?[]const u8) @This() {
    var pattern = raw;

    const negated = pattern.len > 0 and pattern[0] == '!';
    if (negated) pattern = pattern[1..];

    const only_dir = pattern.len > 0 and pattern[pattern.len - 1] == '/';
    if (only_dir) pattern = pattern[0 .. pattern.len - 1];

    var anchored = false;
    if (std.mem.startsWith(u8, pattern, "/")) {
        anchored = true;
        pattern = pattern[1..];
    } else if (std.mem.startsWith(u8, pattern, "./")) {
        anchored = true;
        pattern = pattern[2..];
    } else if (std.mem.indexOfScalar(u8, pattern, '/') != null) {
        anchored = true;
    }

    if (pattern.len > 0 and pattern[0] == '/')
        pattern = pattern[1..];

    const norm_base_dir: ?[]const u8 = if (base_dir) |bd| blk: {
        const trimmed = if (bd.len > 0 and bd[bd.len - 1] == '/') bd[0 .. bd.len - 1] else bd;
        // "." or "" both mean current directory → no prefix restriction
        break :blk if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) null else trimmed;
    } else null;

    return .{
        .pattern = pattern,
        .negated = negated,
        .only_dir = only_dir,
        .anchored = anchored,
        .base_dir = norm_base_dir,
    };
}

pub fn match(self: @This(), path: []const u8, is_dir: bool) bool {
    if (self.only_dir and !is_dir) return false;

    var rel_path = path;
    if (std.mem.startsWith(u8, rel_path, "./")) rel_path = rel_path[2..];
    if (rel_path.len > 0 and rel_path[0] == '/') rel_path = rel_path[1..];

    if (self.base_dir) |bd| {
        if (!std.mem.startsWith(u8, rel_path, bd)) return false;
        const after = rel_path[bd.len..];
        if (after.len == 0)
            rel_path = ""
        else if (after[0] == '/')
            rel_path = after[1..]
        else
            return false;
    }

    if (self.anchored) return globMatch(self.pattern, rel_path);

    var rest: []const u8 = rel_path;
    while (true) {
        if (globMatch(self.pattern, rest)) return true;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
        rest = rest[slash + 1 ..];
    }
}

fn globMatch(pattern: []const u8, str: []const u8) bool {
    return globMatchInner(pattern, 0, str, 0);
}

fn globMatchInner(pat: []const u8, pi: usize, str: []const u8, si: usize) bool {
    var p = pi;
    var s = si;

    while (p < pat.len) {
        if (pat[p] == '*' and p + 1 < pat.len and pat[p + 1] == '*') {
            p += 2;
            if (p < pat.len and pat[p] == '/') p += 1;
            var ss = s;
            while (true) {
                if (globMatchInner(pat, p, str, ss)) return true;
                const slash = std.mem.indexOfScalarPos(u8, str, ss, '/') orelse
                    return globMatchInner(pat, p, str, str.len);
                ss = slash + 1;
            }
        }

        if (pat[p] == '*') {
            p += 1;
            var save_s = s;
            while (true) {
                if (globMatchInner(pat, p, str, save_s)) return true;
                if (save_s >= str.len or str[save_s] == '/') return false;
                save_s += 1;
            }
        }

        if (pat[p] == '?') {
            if (s >= str.len or str[s] == '/') return false;
            p += 1;
            s += 1;
            continue;
        }

        if (s >= str.len or pat[p] != str[s]) return false;
        p += 1;
        s += 1;
    }

    return s == str.len;
}
