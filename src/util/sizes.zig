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
