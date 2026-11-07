const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const Task = @import("../daemon/Task.zig");
const Monitor = @import("../util/Monitor.zig");
const proto = @import("../domain/proto.zig");
const Weft = @import("../domain/Weft.zig");
const Term = @import("../domain/Term.zig");
const zoto = @import("../util/zoto.zig");

pub const types = [_]type{
    Task.Status,
    Task.Spec,
    Task,
    proto.task.Id,

    Deployment,
    Weft,
    Monitor.Stats,

    proto.Request,
    proto.DaemonMsg,

    proto.artifact.push.Req,
    proto.artifact.push.Res,
    proto.Res(proto.artifact.push.Res),

    proto.artifact.pull.Req,
    proto.artifact.pull.Res,
    proto.Res(proto.artifact.pull.Res),

    proto.artifact.has.Req,
    proto.artifact.has.Res,
    proto.Res(proto.artifact.has.Res),

    proto.task.spawn.Req,
    proto.task.spawn.Res,
    proto.Res(proto.task.spawn.Res),

    proto.task.poll.Req,
    proto.task.poll.Res,
    proto.Res(proto.task.poll.Res),

    proto.task.kill.Req,
    proto.task.kill.Res,
    proto.Res(proto.task.kill.Res),

    proto.system.stats.Req,

    proto.Pack,
};

pub fn decode_and_print(
    gpa: std.mem.Allocator,
    raw: []const u8,
    term: *Term,
) !void {
    var data = raw;
    if (std.mem.startsWith(u8, data, "ZOTO"))
        data = data[4..];

    if (data.len < @sizeOf(u64))
        return error.BufferTooSmall;

    const hash = std.mem.readInt(u64, data[0..@sizeOf(u64)], .little);
    const payload = data[@sizeOf(u64)..];

    inline for (types) |T| {
        if (hash == comptime zoto.hashType(T)) {
            var parse_slice = payload;
            const val = try zoto.deserialize(gpa, &parse_slice, T, .{
                .header = false,
                .hash = false,
            });

            term.styled(.cyan, "{s}", .{@typeName(T)});
            try print_value(T, val, term, 0, true);
            term.print(";", .{});
            if (parse_slice.len > 0)
                term.styled(.dim, " # {d} bytes remaining", .{parse_slice.len});
            term.println("", .{});
            return;
        }
    }

    return error.UnknownTypeHash;
}

fn indent(term: *Term, depth: usize) void {
    const w = term.writer();
    var i: usize = 0;
    while (i < depth) : (i += 1)
        w.writeAll("  ") catch {};
}

fn print_string(val: []const u8, term: *Term, depth: usize) void {
    if (std.mem.indexOfScalar(u8, val, '\n')) |_| {
        var lines = std.mem.splitScalar(u8, val, '\n');
        term.println("", .{});
        while (lines.next()) |line| {
            indent(term, depth + 1);
            term.styled(.bright_green, "\\\\{s}", .{line});
            term.println("", .{});
        }
        indent(term, depth);
    } else {
        term.styled(.bright_green, "\"{f}\"", .{std.zig.fmtString(val)});
    }
}

fn print_value(comptime T: type, val: T, term: *Term, depth: usize, is_root: bool) !void {
    const info = @typeInfo(T);
    switch (info) {
        .void => term.styled(.dim, "void", .{}),
        .bool => term.styled(.bright_blue, "{}", .{val}),
        .int => term.styled(.bright_yellow, "{d}", .{val}),
        .float => term.styled(.bright_yellow, "{d}", .{val}),
        .@"enum" => term.styled(.bright_magenta, ".{s}", .{@tagName(val)}),
        .error_set => term.styled(.bright_red, "error.{s}", .{@errorName(val)}),
        .error_union => {
            if (val) |payload|
                try print_value(@TypeOf(payload), payload, term, depth, is_root)
            else |err|
                term.styled(.bright_red, "error.{s}", .{@errorName(err)});
        },
        .optional => {
            if (val) |payload|
                try print_value(@TypeOf(payload), payload, term, depth, false)
            else
                term.styled(.bright_blue, "null", .{});
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    print_string(val, term, depth);
                } else if (val.len == 0) {
                    term.print("&.{{}}", .{});
                } else {
                    term.println("&.{{", .{});
                    for (val) |item| {
                        indent(term, depth + 1);
                        try print_value(p.child, item, term, depth + 1, false);
                        term.println(",", .{});
                    }
                    indent(term, depth);
                    term.print("}}", .{});
                }
            },
            .one => {
                term.print("&", .{});
                try print_value(p.child, val.*, term, depth, false);
            },
            else => term.styled(.dim, "unsupported pointer", .{}),
        },
        .array => |a| {
            if (a.child == u8) {
                print_string(&val, term, depth);
            } else if (val.len == 0) {
                term.print(".{{}}", .{});
            } else {
                term.println(".{{", .{});
                for (val) |item| {
                    indent(term, depth + 1);
                    try print_value(a.child, item, term, depth + 1, false);
                    term.println(",", .{});
                }
                indent(term, depth);
                term.print("}}", .{});
            }
        },
        .@"struct" => |s| {
            const prefix = if (is_root) "" else ".";
            if (s.is_tuple) {
                if (s.field_names.len == 0) {
                    term.print("{s}.{{}}", .{prefix});
                    return;
                }
                term.println("{s}.{{", .{prefix});
                inline for (s.field_names, s.field_types) |f_name, f_type| {
                    indent(term, depth + 1);
                    try print_value(f_type, @field(val, f_name), term, depth + 1, false);
                    term.println(",", .{});
                }
                indent(term, depth);
                term.print("}}", .{});
            } else {
                if (s.field_names.len == 0) {
                    term.print("{s}.{{}}", .{prefix});
                    return;
                }
                term.println("{s}.{{", .{prefix});
                inline for (s.field_names, s.field_types) |f_name, f_type| {
                    indent(term, depth + 1);
                    term.styled(.blue, ".{s}", .{f_name});
                    term.print(" = ", .{});
                    try print_value(f_type, @field(val, f_name), term, depth + 1, false);
                    term.println(",", .{});
                }
                indent(term, depth);
                term.print("}}", .{});
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) {
                term.styled(.dim, "untagged-union", .{});
                return;
            }
            switch (val) {
                inline else => |payload, tag| {
                    if (@TypeOf(payload) == void) {
                        term.styled(.magenta, ".{{ .{s} }}", .{@tagName(tag)});
                    } else {
                        term.styled(.magenta, ".{{ .{s} = ", .{@tagName(tag)});
                        try print_value(@TypeOf(payload), payload, term, depth, false);
                        term.styled(.magenta, " }}", .{});
                    }
                },
            }
        },
        else => term.styled(.dim, "unknown", .{}),
    }
}
