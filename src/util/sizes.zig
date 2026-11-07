const std = @import("std");

pub fn format_bytes(buf: []u8, bytes: u64) std.fmt.BufPrintError![]const u8 {
    const f: f64 = @floatFromInt(bytes);
    return try if (bytes >= 1024 * 1024 * 1024)
        std.fmt.bufPrint(buf, "{d:.1} GB", .{f / (1024.0 * 1024.0 * 1024.0)})
    else if (bytes >= 1024 * 1024)
        std.fmt.bufPrint(buf, "{d:.1} MB", .{f / (1024.0 * 1024.0)})
    else if (bytes >= 1024)
        std.fmt.bufPrint(buf, "{d:.1} KB", .{f / 1024.0})
    else
        std.fmt.bufPrint(buf, "{d} B", .{bytes});
}

pub fn format_duration(buf: []u8, ns: i96) []const u8 {
    return if (ns < 1_000)
        std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch "..."
    else if (ns < 1_000_000)
        std.fmt.bufPrint(buf, "{d:.2}µs", .{@as(f64, @floatFromInt(ns)) / 1_000.0}) catch "..."
    else if (ns < 1_000_000_000)
        std.fmt.bufPrint(buf, "{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch "..."
    else
        std.fmt.bufPrint(buf, "{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0}) catch "...";
}
