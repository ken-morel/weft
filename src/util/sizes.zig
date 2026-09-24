const std = @import("std");

pub fn format_bytes(buf: []u8, bytes: u64) []const u8 {
    const f: f64 = @floatFromInt(bytes);
    if (bytes >= 1024 * 1024 * 1024)
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{f / (1024.0 * 1024.0 * 1024.0)}) catch "..."
    else if (bytes >= 1024 * 1024)
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / (1024.0 * 1024.0)}) catch "..."
    else if (bytes >= 1024)
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / 1024.0}) catch "..."
    else
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "...";
}
