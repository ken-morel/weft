const std = @import("std");

pub const Lang = enum {
    sh,
    bash,
    fish,
    nushell,
    python,
    zig,
    bin,
};

pub const lang_exts = []struct { Lang, [][]const u8 }{
    .{ .sh, &.{"sh"} },
    .{ .bash, &.{"bash"} },
    .{ .fish, &.{"fish"} },
    .{ .nushell, &.{"nu"} },
    .{ .python, &.{ "py", "pyc", "py3" } },
    .{ .zig, &.{"zig"} },
    .{ .bin, &.{""} },
};

pub fn get_lang_by_file_name(path: []const u8) ?Lang {
    const ext = std.fs.path.extension(path);
    for (lang_exts) |lang_ext_map|
        for (lang_ext_map.@"1") |lang_ext|
            if (std.mem.eql(ext, lang_ext))
                return lang_ext_map.@"0";
    return null;
}
