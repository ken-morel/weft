const std = @import("std");

pattern: []const u8,
negated: bool,
only_dir: bool,

pub fn parse(raw: []const u8) @This() {
    var pattern = raw;
    const negated = pattern.len > 0 and pattern[0] == '!';
    if (negated)
        pattern = pattern[1..];
    const only_dir = pattern.len > 0 and pattern[pattern.len - 1] == '/';
    if (only_dir)
        pattern = pattern[0 .. pattern.len - 1];
    return .{
        .pattern = pattern,
        .negated = negated,
        .only_dir = only_dir,
    };
}

pub fn match(self: @This(), path: []const u8, is_dir: bool) bool {
    if (self.only_dir and !is_dir) return false;

    var pat_idx: usize = 0;
    var str_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    const pat = self.pattern;

    while (str_idx < path.len) {
        // 1. Exact character match OR '?' single-char wildcard
        if (pat_idx < pat.len and (pat[pat_idx] == '?' or pat[pat_idx] == path[str_idx])) {
            pat_idx += 1;
            str_idx += 1;
        }
        // 2. Hit a '*', drop a save point and try to match 0 characters first
        else if (pat_idx < pat.len and pat[pat_idx] == '*') {
            star_idx = pat_idx;
            match_idx = str_idx;
            pat_idx += 1;
        }
        // 3. Current char failed, but we have a '*' save point! Backtrack and consume 1 more char
        else if (star_idx) |star| {
            pat_idx = star + 1;
            match_idx += 1;
            str_idx = match_idx;
        }
        // 4. Failed to match and no '*' to save us
        else {
            return false;
        }
    }

    // Consume any trailing '*' at the end of the pattern (e.g. pattern "foo*" matching path "foo")
    while (pat_idx < pat.len and pat[pat_idx] == '*') {
        pat_idx += 1;
    }

    // If we reached the end of the pattern, it's a match
    return pat_idx == pat.len;
}

const testing = std.testing;

test "Glob - basic wildcards" {
    const glob = @This().parse("*.zig");

    try testing.expect(glob.match("main.zig", false));
    try testing.expect(glob.match("parser.zig", false));
    try testing.expect(!glob.match("main.c", false));
    try testing.expect(!glob.match("zig", false)); // No dot
}

test "Glob - single character wildcard" {
    const glob = @This().parse("test_?.zig");

    try testing.expect(glob.match("test_1.zig", false));
    try testing.expect(glob.match("test_a.zig", false));
    try testing.expect(!glob.match("test_10.zig", false)); // '?' is strictly one char
}

test "Glob - negation and directory flags" {
    // A negated directory match (like "!node_modules/")
    const glob = @This().parse("!node_modules/");

    try testing.expect(glob.negated == true);
    try testing.expect(glob.only_dir == true);

    // It should match the string "node_modules" ONLY if path_is_dir is true
    try testing.expect(glob.match("node_modules", true));
    try testing.expect(!glob.match("node_modules", false));
}

test "Glob - complex internal wildcards" {
    const glob = @This().parse("src/*/main.*");

    try testing.expect(glob.match("src/parser/main.zig", false));
    try testing.expect(glob.match("src/db/main.c", false));
    try testing.expect(!glob.match("src/main.zig", false)); // missing the middle folder
}
