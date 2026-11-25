const std = @import("std");
const log = std.log.scoped;

pub const Error = std.mem.Allocator.Error || error{
    ParseZoton,
    InvalidType,
    InvalidInt,
    InvalidEnum,
    InvalidError,
    InvalidUnion,
    MissingField,
    UnknownField,
    LengthMismatch,
    UnsupportedAnyerror,
};

pub const Context = struct {
    ast: *const std.zig.Ast,
    zoir: *const std.zig.Zoir,

    pub fn log_err(self: @This(), node_idx: std.zig.Zoir.Node.Index, comptime fmt: []const u8, args: anytype) void {
        const l = log(.zoton);
        const tok = self.ast.firstToken(node_idx.getAstNode(self.zoir));
        const loc = self.ast.tokenLocation(0, tok);
        l.err("{d}:{d}: " ++ fmt, .{ loc.line + 1, loc.column + 1 } ++ args);
    }

    pub fn parse_leaky(
        self: @This(),
        ara: std.mem.Allocator,
        node_idx: std.zig.Zoir.Node.Index,
        comptime T: type,
    ) Error!T {
        return try from_zoir_leaky(ara, self, node_idx, T);
    }
};

pub fn Map(comptime V: type) type {
    return struct {
        pub const Entry = struct { []const u8, V };

        items: []const Entry = &.{},

        pub fn get(self: @This(), key: []const u8) ?V {
            return for (self.items) |entry| {
                if (std.mem.eql(u8, entry.@"0", key))
                    break entry.@"1";
            } else null;
        }

        pub fn get_ptr(self: @This(), key: []const u8) ?*const V {
            return for (self.items) |*entry| {
                if (std.mem.eql(u8, entry.@"0", key))
                    break &entry.@"1";
            } else null;
        }

        pub fn zoton_serialize(self: @This(), out: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
            if (self.items.len == 0)
                try out.writeAll(".{}")
            else {
                try out.writeAll(".{\n");
                for (self.items) |entry| {
                    try indent(out, depth + 1);
                    try out.print(".{f} = ", .{std.zig.fmtId(entry.@"0")});
                    try serialize_value(V, entry.@"1", out, depth + 1);
                    try out.writeAll(",\n");
                }
                try indent(out, depth);
                try out.writeAll("}");
            }
        }

        pub fn zoton_deserialize_leaky(
            ara: std.mem.Allocator,
            ctx: Context,
            node_idx: std.zig.Zoir.Node.Index,
        ) Error!@This() {
            return switch (node_idx.get(ctx.zoir)) {
                .empty_literal => .{},
                .struct_literal => |sl| map: {
                    const entries = try ara.alloc(Entry, sl.names.len);
                    for (sl.names, 0..) |nts, i|
                        entries[i] = .{
                            try ara.dupe(u8, nts.get(ctx.zoir)),
                            if (comptime @typeInfo(V) == .error_set)
                                (try error_set_from_zoir(ctx, sl.vals.at(@intCast(i)), V)).err
                            else
                                try ctx.parse_leaky(ara, sl.vals.at(@intCast(i)), V),
                        };
                    break :map .{ .items = entries };
                },
                else => |node| {
                    ctx.log_err(node_idx, "expected map struct literal for {s}, found {s}", .{ @typeName(@This()), @tagName(node) });
                    return error.InvalidType;
                },
            };
        }
    };
}

pub fn NamedMap(comptime key_field: @EnumLiteral(), comptime V: type) type {
    const key_name = @tagName(key_field);
    const info = @typeInfo(V);
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("zoton.NamedMap requires a non-tuple struct type, got " ++ @typeName(V));
    if (!@hasField(V, key_name))
        @compileError("zoton.NamedMap key field '" ++ key_name ++ "' does not exist on " ++ @typeName(V));
    if (@FieldType(V, key_name) != []const u8)
        @compileError("zoton.NamedMap key field '" ++ key_name ++ "' on " ++ @typeName(V) ++ " must be []const u8");

    return struct {
        items: []const V = &.{},

        pub fn get(self: @This(), key: []const u8) ?*const V {
            return for (self.items) |*item| {
                if (std.mem.eql(u8, @field(item.*, key_name), key))
                    break item;
            } else null;
        }

        pub fn zoton_serialize(self: @This(), out: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
            if (self.items.len == 0)
                try out.writeAll(".{}")
            else {
                try out.writeAll(".{\n");
                for (self.items) |item| {
                    try indent(out, depth + 1);
                    try out.print(".{f} = ", .{std.zig.fmtId(@field(item, key_name))});
                    try serialize_struct(V, item, out, depth + 1, key_name);
                    try out.writeAll(",\n");
                }
                try indent(out, depth);
                try out.writeAll("}");
            }
        }

        pub fn zoton_deserialize_leaky(
            ara: std.mem.Allocator,
            ctx: Context,
            node_idx: std.zig.Zoir.Node.Index,
        ) Error!@This() {
            return switch (node_idx.get(ctx.zoir)) {
                .empty_literal => .{},
                .struct_literal => |sl| map: {
                    const entries = try ara.alloc(V, sl.names.len);
                    for (sl.names, 0..) |nts, i| {
                        const key = try ara.dupe(u8, nts.get(ctx.zoir));
                        entries[i] = try parse_struct_leaky(ara, ctx, sl.vals.at(@intCast(i)), V, key_name, key);
                    }
                    break :map .{ .items = entries };
                },
                else => |node| {
                    ctx.log_err(node_idx, "expected map struct literal for {s}, found {s}", .{ @typeName(@This()), @tagName(node) });
                    return error.InvalidType;
                },
            };
        }
    };
}

fn has_decl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, name),
        else => false,
    };
}

fn is_hidden_field(comptime name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__");
}

pub fn indent(out: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < depth) : (i += 1)
        try out.writeAll("  ");
}

fn is_multiline_string(val: []const u8) bool {
    if (std.mem.indexOfScalar(u8, val, '\n') == null)
        return false;
    if (!std.unicode.utf8ValidateSlice(val))
        return false;
    return for (val) |c| {
        if ((c < 0x20 and c != '\n' and c != '\t') or c == 0x7f)
            break false;
    } else true;
}

fn write_string(val: []const u8, out: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    if (is_multiline_string(val)) {
        var lines = std.mem.splitScalar(u8, val, '\n');
        try out.writeByte('\n');
        while (lines.next()) |line| {
            try indent(out, depth + 1);
            try out.print("\\\\{s}\n", .{line});
        }
        try indent(out, depth);
    } else try out.print("\"{f}\"", .{std.zig.fmtString(val)});
}

fn is_ambiguous_error_union_payload(comptime P: type) bool {
    return switch (@typeInfo(P)) {
        .@"enum", .error_set, .error_union, .@"union" => true,
        else => false,
    };
}

pub fn serialize(out: *std.Io.Writer, comptime T: type, val: T) std.Io.Writer.Error!void {
    try serialize_value(T, val, out, 0);
}

fn serialize_struct(
    comptime T: type,
    val: T,
    out: *std.Io.Writer,
    depth: usize,
    comptime omit_field: ?[]const u8,
) std.Io.Writer.Error!void {
    const s = @typeInfo(T).@"struct";
    const visible_count = comptime count: {
        var n: usize = 0;
        for (s.field_names) |f_name| {
            if (is_hidden_field(f_name))
                continue;
            if (omit_field) |omit|
                if (std.mem.eql(u8, f_name, omit))
                    continue;
            n += 1;
        }
        break :count n;
    };

    if (visible_count == 0)
        try out.writeAll(".{}")
    else {
        try out.writeAll(".{\n");
        inline for (s.field_names, s.field_types) |f_name, f_type| {
            const skip = comptime is_hidden_field(f_name) or
                (if (omit_field) |omit| std.mem.eql(u8, f_name, omit) else false);
            if (!skip) {
                try indent(out, depth + 1);
                try out.print(".{f} = ", .{std.zig.fmtId(f_name)});
                try serialize_value(f_type, @field(val, f_name), out, depth + 1);
                try out.writeAll(",\n");
            }
        }
        try indent(out, depth);
        try out.writeAll("}");
    }
}

pub fn serialize_value(comptime T: type, val: T, out: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    if (comptime has_decl(T, "zoton_serialize"))
        return try val.zoton_serialize(out, depth);

    switch (@typeInfo(T)) {
        .void => try out.writeAll(".{}"),
        .bool => try out.print("{}", .{val}),
        .int => try out.print("{d}", .{val}),
        .float => if (std.math.isNan(val))
            try out.writeAll("nan")
        else if (std.math.isPositiveInf(val))
            try out.writeAll("inf")
        else if (std.math.isNegativeInf(val))
            try out.writeAll("-inf")
        else
            try out.print("{d}", .{val}),
        .@"enum" => try out.print(".{f}", .{std.zig.fmtId(@tagName(val))}),
        .error_set => try out.print(".{f}", .{std.zig.fmtId(@errorName(val))}),
        .error_union => |eu| if (comptime is_ambiguous_error_union_payload(eu.payload)) {
            if (val) |payload| {
                try out.writeAll(".{ .ok = ");
                try serialize_value(eu.payload, payload, out, depth);
                try out.writeAll(" }");
            } else |err| try out.print(".{{ .err = .{f} }}", .{std.zig.fmtId(@errorName(err))});
        } else if (val) |payload|
            try serialize_value(eu.payload, payload, out, depth)
        else |err|
            try out.print(".{f}", .{std.zig.fmtId(@errorName(err))}),
        .optional => if (val) |payload|
            try serialize_value(@TypeOf(payload), payload, out, depth)
        else
            try out.writeAll("null"),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8)
                try write_string(val, out, depth)
            else if (val.len == 0)
                try out.writeAll(".{}")
            else if (val.len == 1) {
                try out.writeAll(".{ ");
                try serialize_value(p.child, val[0], out, depth + 1);
                try out.writeAll(" }");
            } else {
                try out.writeAll(".{\n");
                for (val) |item| {
                    try indent(out, depth + 1);
                    try serialize_value(p.child, item, out, depth + 1);
                    try out.writeAll(",\n");
                }
                try indent(out, depth);
                try out.writeAll("}");
            },
            .one => try serialize_value(p.child, val.*, out, depth),
            else => @compileError("Unsupported pointer size for zoton: " ++ @typeName(T)),
        },
        .array => |a| if (a.child == u8)
            try out.print("\"{f}\"", .{std.zig.fmtString(&val)})
        else if (val.len == 0)
            try out.writeAll(".{}")
        else if (val.len == 1) {
            try out.writeAll(".{ ");
            try serialize_value(a.child, val[0], out, depth + 1);
            try out.writeAll(" }");
        } else {
            try out.writeAll(".{\n");
            for (val) |item| {
                try indent(out, depth + 1);
                try serialize_value(a.child, item, out, depth + 1);
                try out.writeAll(",\n");
            }
            try indent(out, depth);
            try out.writeAll("}");
        },
        .@"struct" => |s| if (s.is_tuple) {
            if (s.field_names.len == 0)
                try out.writeAll(".{}")
            else {
                try out.writeAll(".{\n");
                inline for (s.field_names, s.field_types) |f_name, f_type| {
                    try indent(out, depth + 1);
                    try serialize_value(f_type, @field(val, f_name), out, depth + 1);
                    try out.writeAll(",\n");
                }
                try indent(out, depth);
                try out.writeAll("}");
            }
        } else try serialize_struct(T, val, out, depth, null),
        .@"union" => |u| {
            if (u.tag_type == null)
                @compileError("Union must be tagged for zoton: " ++ @typeName(T));
            switch (val) {
                inline else => |payload, tag| if (@TypeOf(payload) == void)
                    try out.print(".{f}", .{std.zig.fmtId(@tagName(tag))})
                else {
                    try out.print(".{{ .{f} = ", .{std.zig.fmtId(@tagName(tag))});
                    try serialize_value(@TypeOf(payload), payload, out, depth);
                    try out.writeAll(" }");
                },
            }
        },
        else => @compileError("Unsupported type for zoton serialization: " ++ @typeName(T)),
    }
}

pub fn deserialize_leaky(
    gpa: std.mem.Allocator,
    ara: std.mem.Allocator,
    source: [:0]const u8,
    comptime T: type,
) Error!T {
    var ast = try std.zig.Ast.parse(gpa, source, .{ .mode = .zon });
    defer ast.deinit(gpa);

    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    defer zoir.deinit(gpa);

    if (zoir.hasCompileErrors()) {
        const l = log(.zoton);
        for (zoir.compile_errors) |err| {
            const msg = err.msg.get(&zoir);
            if (err.token.unwrap()) |tok| {
                const loc = ast.tokenLocation(0, tok);
                l.err("{d}:{d}: {s}", .{ loc.line + 1, loc.column + 1, msg });
            } else l.err("{s}", .{msg});
        }
        return error.ParseZoton;
    }

    return try from_zoir_leaky(ara, .{ .ast = &ast, .zoir = &zoir }, .root, T);
}

fn error_set_from_zoir(ctx: Context, node_idx: std.zig.Zoir.Node.Index, comptime E: type) Error!struct { err: E } {
    const fields = @typeInfo(E).error_set.error_names orelse {
        ctx.log_err(node_idx, "cannot deserialize open error set 'anyerror'", .{});
        return error.UnsupportedAnyerror;
    };
    return switch (node_idx.get(ctx.zoir)) {
        .enum_literal => |nts| blk: {
            const name = nts.get(ctx.zoir);
            break :blk inline for (fields) |f| {
                if (std.mem.eql(u8, name, f))
                    break .{ .err = @field(E, f) };
            } else {
                ctx.log_err(node_idx, "unknown error '.{s}' for {s}", .{ name, @typeName(E) });
                break :blk error.InvalidError;
            };
        },
        else => |node| {
            ctx.log_err(node_idx, "expected error literal for {s}, found {s}", .{ @typeName(E), @tagName(node) });
            return error.InvalidType;
        },
    };
}

fn parse_struct_leaky(
    ara: std.mem.Allocator,
    ctx: Context,
    node_idx: std.zig.Zoir.Node.Index,
    comptime T: type,
    comptime inject_field: ?[]const u8,
    inject_val: ?[]const u8,
) Error!T {
    const s = @typeInfo(T).@"struct";
    const zoir = ctx.zoir;
    const node = node_idx.get(zoir);

    inline for (s.field_names, s.field_types, s.field_attrs) |f_name, f_type, f_attr| {
        if (comptime is_hidden_field(f_name)) {
            if (comptime f_attr.defaultValue(f_type) == null)
                @compileError("zoton: '__'-prefixed field '" ++ f_name ++ "' in " ++ @typeName(T) ++ " must have a default value");
        }
    }

    return switch (node) {
        .empty_literal => res: {
            var res: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |f_name, f_type, f_attr| {
                const is_injected = comptime if (inject_field) |inj| std.mem.eql(u8, f_name, inj) else false;
                if (is_injected)
                    @field(res, f_name) = inject_val orelse unreachable
                else if (comptime is_hidden_field(f_name))
                    @field(res, f_name) = comptime f_attr.defaultValue(f_type) orelse unreachable
                else
                    @field(res, f_name) = f_attr.defaultValue(f_type) orelse {
                        ctx.log_err(node_idx, "missing required field '.{s}' in {s}", .{ f_name, @typeName(T) });
                        return error.MissingField;
                    };
            }
            break :res res;
        },
        .struct_literal => |sl| res: {
            for (sl.names, 0..) |nts, i| {
                const name = nts.get(zoir);
                const known = inline for (s.field_names) |f_name| {
                    const forbidden = comptime is_hidden_field(f_name) or
                        (if (inject_field) |inj| std.mem.eql(u8, f_name, inj) else false);
                    if (!forbidden and std.mem.eql(u8, name, f_name))
                        break true;
                } else false;
                if (!known) {
                    ctx.log_err(sl.vals.at(@intCast(i)), "unknown field '.{s}' in {s}", .{ name, @typeName(T) });
                    return error.UnknownField;
                }
            }
            var res: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |f_name, f_type, f_attr| {
                const is_injected = comptime if (inject_field) |inj| std.mem.eql(u8, f_name, inj) else false;
                if (is_injected)
                    @field(res, f_name) = inject_val orelse unreachable
                else if (comptime is_hidden_field(f_name))
                    @field(res, f_name) = comptime f_attr.defaultValue(f_type) orelse unreachable
                else {
                    const found_idx: ?u32 = idx: for (sl.names, 0..) |nts, i| {
                        if (std.mem.eql(u8, nts.get(zoir), f_name))
                            break :idx @intCast(i);
                    } else null;
                    @field(res, f_name) = if (found_idx) |i|
                        if (comptime @typeInfo(f_type) == .error_set)
                            (try error_set_from_zoir(ctx, sl.vals.at(i), f_type)).err
                        else
                            try from_zoir_leaky(ara, ctx, sl.vals.at(i), f_type)
                    else
                        f_attr.defaultValue(f_type) orelse {
                            ctx.log_err(node_idx, "missing required field '.{s}' in {s}", .{ f_name, @typeName(T) });
                            return error.MissingField;
                        };
                }
            }
            break :res res;
        },
        else => {
            ctx.log_err(node_idx, "expected struct {s}, found {s}", .{ @typeName(T), @tagName(node) });
            return error.InvalidType;
        },
    };
}

fn from_zoir_leaky(
    ara: std.mem.Allocator,
    ctx: Context,
    node_idx: std.zig.Zoir.Node.Index,
    comptime T: type,
) Error!T {
    if (comptime has_decl(T, "zoton_deserialize_leaky"))
        return try T.zoton_deserialize_leaky(ara, ctx, node_idx);

    const zoir = ctx.zoir;
    const node = node_idx.get(zoir);
    return switch (@typeInfo(T)) {
        .void => switch (node) {
            .empty_literal => {},
            else => {
                ctx.log_err(node_idx, "expected void (.{{}}), found {s}", .{@tagName(node)});
                return error.InvalidType;
            },
        },
        .bool => switch (node) {
            .true => true,
            .false => false,
            else => {
                ctx.log_err(node_idx, "expected bool, found {s}", .{@tagName(node)});
                return error.InvalidType;
            },
        },
        .int => switch (node) {
            .int_literal => |lit| switch (lit) {
                .small => |v| std.math.cast(T, v) orelse {
                    ctx.log_err(node_idx, "integer {d} out of range for {s}", .{ v, @typeName(T) });
                    return error.InvalidInt;
                },
                .big => |b| b.toInt(T) catch {
                    ctx.log_err(node_idx, "integer out of range for {s}", .{@typeName(T)});
                    return error.InvalidInt;
                },
            },
            .char_literal => |c| std.math.cast(T, c) orelse {
                ctx.log_err(node_idx, "char literal out of range for {s}", .{@typeName(T)});
                return error.InvalidInt;
            },
            else => {
                ctx.log_err(node_idx, "expected {s}, found {s}", .{ @typeName(T), @tagName(node) });
                return error.InvalidType;
            },
        },
        .float => switch (node) {
            .float_literal => |f| @floatCast(f),
            .int_literal => |lit| switch (lit) {
                .small => |v| @floatFromInt(v),
                .big => |b| b.toFloat(T, .nearest_even)[0],
            },
            .pos_inf => std.math.inf(T),
            .neg_inf => -std.math.inf(T),
            .nan => std.math.nan(T),
            else => {
                ctx.log_err(node_idx, "expected {s}, found {s}", .{ @typeName(T), @tagName(node) });
                return error.InvalidType;
            },
        },
        .@"enum" => |e| switch (node) {
            .enum_literal => |nts| blk: {
                const name = nts.get(zoir);
                break :blk inline for (e.field_names) |f| {
                    if (std.mem.eql(u8, name, f))
                        break @field(T, f);
                } else {
                    ctx.log_err(node_idx, "unknown enum tag '.{s}' for {s}", .{ name, @typeName(T) });
                    break :blk error.InvalidEnum;
                };
            },
            else => {
                ctx.log_err(node_idx, "expected enum literal for {s}, found {s}", .{ @typeName(T), @tagName(node) });
                return error.InvalidType;
            },
        },
        .error_union => |eu| switch (node) {
            .struct_literal => |sl| if (sl.names.len == 1 and std.mem.eql(u8, sl.names[0].get(zoir), "err"))
                @as(T, (try error_set_from_zoir(ctx, sl.vals.at(0), eu.error_set)).err)
            else if (sl.names.len == 1 and std.mem.eql(u8, sl.names[0].get(zoir), "ok"))
                @as(T, try from_zoir_leaky(ara, ctx, sl.vals.at(0), eu.payload))
            else
                @as(T, try from_zoir_leaky(ara, ctx, node_idx, eu.payload)),
            .enum_literal => if (comptime !is_ambiguous_error_union_payload(eu.payload))
                @as(T, (try error_set_from_zoir(ctx, node_idx, eu.error_set)).err)
            else {
                ctx.log_err(node_idx, "ambiguous enum literal for {s}; use .{{ .ok = ... }} or .{{ .err = ... }}", .{@typeName(T)});
                return error.InvalidType;
            },
            else => @as(T, try from_zoir_leaky(ara, ctx, node_idx, eu.payload)),
        },
        .optional => |o| switch (node) {
            .null => null,
            else => if (comptime @typeInfo(o.child) == .error_set)
                @as(T, (try error_set_from_zoir(ctx, node_idx, o.child)).err)
            else
                try from_zoir_leaky(ara, ctx, node_idx, o.child),
        },
        .pointer => |p| switch (p.size) {
            .slice => switch (node) {
                .string_literal => |s| if (p.child == u8)
                    try ara.dupe(u8, s)
                else {
                    ctx.log_err(node_idx, "expected slice {s}, found string_literal", .{@typeName(T)});
                    return error.InvalidType;
                },
                .empty_literal => if (p.attrs.@"const")
                    &.{}
                else
                    try ara.alloc(p.child, 0),
                .array_literal => |range| slice: {
                    const out = try ara.alloc(p.child, range.len);
                    for (0..range.len) |i|
                        out[i] = if (comptime @typeInfo(p.child) == .error_set)
                            (try error_set_from_zoir(ctx, range.at(@intCast(i)), p.child)).err
                        else
                            try from_zoir_leaky(ara, ctx, range.at(@intCast(i)), p.child);
                    break :slice out;
                },
                else => {
                    ctx.log_err(node_idx, "expected slice {s}, found {s}", .{ @typeName(T), @tagName(node) });
                    return error.InvalidType;
                },
            },
            .one => ptr: {
                const ptr = try ara.create(p.child);
                ptr.* = if (comptime @typeInfo(p.child) == .error_set)
                    (try error_set_from_zoir(ctx, node_idx, p.child)).err
                else
                    try from_zoir_leaky(ara, ctx, node_idx, p.child);
                break :ptr ptr;
            },
            else => @compileError("Unsupported pointer size for zoton: " ++ @typeName(T)),
        },
        .array => |a| switch (node) {
            .string_literal => |s| if (a.child == u8) arr: {
                if (s.len != a.len) {
                    ctx.log_err(node_idx, "expected string length {d} for {s}, found {d}", .{ a.len, @typeName(T), s.len });
                    return error.LengthMismatch;
                }
                var arr: T = undefined;
                @memcpy(&arr, s);
                break :arr arr;
            } else {
                ctx.log_err(node_idx, "expected array {s}, found string_literal", .{@typeName(T)});
                return error.InvalidType;
            },
            .empty_literal => if (a.len == 0)
                .{}
            else {
                ctx.log_err(node_idx, "expected array length {d} for {s}, found 0", .{ a.len, @typeName(T) });
                return error.LengthMismatch;
            },
            .array_literal => |range| arr: {
                if (range.len != a.len) {
                    ctx.log_err(node_idx, "expected array length {d} for {s}, found {d}", .{ a.len, @typeName(T), range.len });
                    return error.LengthMismatch;
                }
                var arr: T = undefined;
                for (0..a.len) |i|
                    arr[i] = if (comptime @typeInfo(a.child) == .error_set)
                        (try error_set_from_zoir(ctx, range.at(@intCast(i)), a.child)).err
                    else
                        try from_zoir_leaky(ara, ctx, range.at(@intCast(i)), a.child);
                break :arr arr;
            },
            else => {
                ctx.log_err(node_idx, "expected array {s}, found {s}", .{ @typeName(T), @tagName(node) });
                return error.InvalidType;
            },
        },
        .@"struct" => |s| if (s.is_tuple) switch (node) {
            .empty_literal => if (s.field_names.len == 0)
                .{}
            else {
                ctx.log_err(node_idx, "expected tuple length {d} for {s}, found 0", .{ s.field_names.len, @typeName(T) });
                return error.LengthMismatch;
            },
            .array_literal => |range| tuple: {
                if (range.len != s.field_names.len) {
                    ctx.log_err(node_idx, "expected tuple length {d} for {s}, found {d}", .{ s.field_names.len, @typeName(T), range.len });
                    return error.LengthMismatch;
                }
                var res: T = undefined;
                inline for (s.field_names, s.field_types, 0..) |f_name, f_type, i|
                    @field(res, f_name) = if (comptime @typeInfo(f_type) == .error_set)
                        (try error_set_from_zoir(ctx, range.at(@intCast(i)), f_type)).err
                    else
                        try from_zoir_leaky(ara, ctx, range.at(@intCast(i)), f_type);
                break :tuple res;
            },
            else => {
                ctx.log_err(node_idx, "expected tuple {s}, found {s}", .{ @typeName(T), @tagName(node) });
                return error.InvalidType;
            },
        } else try parse_struct_leaky(ara, ctx, node_idx, T, null, null),
        .@"union" => |u| blk: {
            if (u.tag_type == null)
                @compileError("Union must be tagged for zoton: " ++ @typeName(T));
            break :blk switch (node) {
                .enum_literal => |nts| tag: {
                    const name = nts.get(zoir);
                    break :tag inline for (u.field_names, u.field_types) |f_name, f_type| {
                        if (std.mem.eql(u8, name, f_name)) {
                            if (f_type == void)
                                break @unionInit(T, f_name, {})
                            else {
                                ctx.log_err(node_idx, "union variant '.{s}' in {s} requires a payload", .{ name, @typeName(T) });
                                break :tag error.InvalidUnion;
                            }
                        }
                    } else {
                        ctx.log_err(node_idx, "unknown union variant '.{s}' for {s}", .{ name, @typeName(T) });
                        break :tag error.InvalidUnion;
                    };
                },
                .struct_literal => |sl| tag: {
                    if (sl.names.len != 1) {
                        ctx.log_err(node_idx, "expected single-field union literal for {s}, found {d} fields", .{ @typeName(T), sl.names.len });
                        return error.InvalidUnion;
                    }
                    const name = sl.names[0].get(zoir);
                    break :tag inline for (u.field_names, u.field_types) |f_name, f_type| {
                        if (std.mem.eql(u8, name, f_name)) {
                            const payload = if (comptime @typeInfo(f_type) == .error_set)
                                (try error_set_from_zoir(ctx, sl.vals.at(0), f_type)).err
                            else
                                try from_zoir_leaky(ara, ctx, sl.vals.at(0), f_type);
                            break @unionInit(T, f_name, payload);
                        }
                    } else {
                        ctx.log_err(node_idx, "unknown union variant '.{s}' for {s}", .{ name, @typeName(T) });
                        break :tag error.InvalidUnion;
                    };
                },
                else => {
                    ctx.log_err(node_idx, "expected union {s}, found {s}", .{ @typeName(T), @tagName(node) });
                    return error.InvalidType;
                },
            };
        },
        else => @compileError("Unsupported type for zoton deserialization: " ++ @typeName(T)),
    };
}
