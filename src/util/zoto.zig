const std = @import("std");
const log = std.log.scoped;

pub const n = @import("zoton.zig");

const endian: std.lang.Endian = .little;

/// Serialization and deserialization options
pub const Options = struct {
    /// The serialized data contains a header
    header: bool = false,
    /// Whether to include a 64-bit type hash
    hash: bool = true,
};

/// Get a 64-bit structural hash of type T
pub fn hashType(comptime T: type) u64 {
    @setEvalBranchQuota(100_000);
    var h: u64 = @intCast(14695981039346656037);
    const prime = 1099511628211;

    const info = @typeInfo(T);

    for (@tagName(info)) |char|
        h = (h ^ char) *% prime;

    switch (info) {
        .void => {},
        .bool => h = (h ^ @as(u64, 1)) *% prime,
        .int => |i| {
            h = (h ^ i.bits) *% prime;
            h = (h ^ @backingInt(i.signedness)) *% prime;
        },
        .float => |f| h = (f.bits ^ h) *% prime,
        .@"struct" => |s| {
            for (s.field_names, s.field_types) |f_name, f_type| {
                for (f_name) |char|
                    h = (h ^ char) *% prime;
                h = (h ^ hashType(f_type)) *% prime;
            }
        },

        .@"union" => |u| {
            if (u.tag_type) |tt|
                h = (h ^ hashType(tt)) *% prime;
            for (u.field_names, u.field_types) |f_name, f_type| {
                for (f_name) |char|
                    h = (h ^ char) *% prime;
                h = (h ^ hashType(f_type)) *% prime;
            }
        },

        .@"enum" => |e| {
            h = (h ^ hashType(e.tag_type)) *% prime;
            //BUG: f_value is truncated to a u64; may lead to hard to find errors with larger types
            inline for (e.field_names, e.field_values) |f_name, f_value| {
                inline for (f_name) |char|
                    h = (h ^ char) *% prime;
                h = (h ^ @as(u64, @truncate(f_value))) *% prime;
            }
        },

        .pointer => |p| {
            h = (h ^ 0xCAFE) *% prime;
            h = (h ^ @backingInt(p.size)) *% prime;
            h = (h ^ @as(u64, if (p.attrs.@"const") 1 else 0)) *% prime;
            h = (h ^ hashType(p.child)) *% prime;
        },

        .array => |a| {
            h = (h ^ 0xBE5F) *% prime;
            h = (h ^ a.len) *% prime;
            h = (h ^ hashType(a.child)) *% prime;
        },

        .optional => |o| {
            h = (h ^ 0xBEEF) *% prime;
            h = (h ^ hashType(o.child)) *% prime;
        },

        .error_set => |es| if (es.error_names) |fields| {
            h = (h ^ 0xBAEF) *% prime;
            for (fields) |f| {
                for (f) |char|
                    h = (h ^ char) *% prime;
                h = (h ^ @as(u64, 0)) *% prime;
            }
        } else {
            h = (h ^ 0xA0EE) *% prime;
        },

        .error_union => |eu| {
            h = (h ^ hashType(eu.error_set)) *% prime;
            h = (h ^ hashType(eu.payload)) *% prime;
        },

        else => @compileError("Zoto does not support hashing type: " ++ @typeName(T)),
    }
    return h;
}

pub fn serialize(writer: *std.Io.Writer, comptime T: type, value: T, opts: Options) std.Io.Writer.Error!void {
    if (opts.header)
        try writer.writeAll("ZOTO");
    if (opts.hash)
        try writeInt(writer, u64, comptime hashType(T));
    try serializeValue(writer, T, value);
}
pub fn serializeAlloc(gpa: std.mem.Allocator, comptime T: type, value: T, opts: Options) (std.Io.Writer.Error || std.mem.Allocator.Error)![]const u8 {
    var allocating: std.Io.Writer.Allocating = .init(gpa);
    errdefer allocating.deinit();
    try serialize(&allocating.writer, T, value, opts);
    return try allocating.toOwnedSlice();
}

fn serializeValue(writer: *std.Io.Writer, comptime T: type, value: T) std.Io.Writer.Error!void {
    const info = @typeInfo(T);

    switch (info) {
        inline .int => try writeInt(writer, T, value),
        inline .float => |f| try writer.writeInt(
            @Int(.unsigned, f.bits),
            @bitCast(value),
            endian,
        ),

        inline .bool => try writer.writeByte(
            if (value)
                std.math.maxInt(u8)
            else
                std.math.minInt(u8),
        ),
        inline .optional => |o| if (value) |payload| {
            try writer.writeByte(std.math.maxInt(u8));
            try serializeValue(writer, o.child, payload);
        } else try writer.writeByte(std.math.minInt(u8)),
        inline .@"struct" => |s| {
            inline for (s.field_names, s.field_types) |f_name, f_type|
                try serializeValue(
                    writer,
                    f_type,
                    @field(value, f_name),
                );
        },

        inline .@"enum" => try writeInt(writer, std.meta.BackingInt(T), @backingInt(value)),
        inline .@"union" => {
            try writer.writeByte(@intCast(@backingInt(std.meta.activeTag(value))));
            switch (value) {
                inline else => |payload| try serializeValue(
                    writer,
                    @TypeOf(payload),
                    payload,
                ),
            }
        },
        inline .pointer => |p| switch (p.size) {
            inline .slice => {
                try writer.writeInt(u64, value.len, endian);
                for (value) |item|
                    try serializeValue(writer, p.child, item);
            },
            inline .one => try serializeValue(writer, p.child, value.*),
            inline else => @compileError("Unsupported pointer size for zoto: " ++ @typeName(T)),
        },
        inline .array => |a| for (value) |item|
            try serializeValue(writer, a.child, item),
        inline .error_set => |es| if (es.error_names != null)
            try serializeValue(writer, []const u8, @errorName(value))
        else
            try serializeValue(writer, u16, @intFromError(value)),
        inline .error_union => |eu| if (value) |payload| {
            try writer.writeByte(1);
            try serializeValue(writer, eu.payload, payload);
        } else |err| {
            try writer.writeByte(0);
            try serializeValue(writer, eu.error_set, err);
        },
        inline .void => {},
        else => @compileError("Unsupported type for zoto serialization: " ++ @typeName(T)),
    }
}

pub fn deserialize(ara: ?std.mem.Allocator, src: *[]const u8, comptime T: type, opts: Options) DeserializeError!T {
    const l = log(.zoto);
    if (opts.header) {
        const header = try readSlice(src, 4);
        if (!std.mem.eql(u8, header, "ZOTO")) {
            l.err("invalid zoto header for {s}", .{@typeName(T)});
            return error.InvalidHeader;
        }
    }

    if (opts.hash) {
        const actual_hash = try readInt(src, u64);
        if (actual_hash != comptime hashType(T)) {
            l.err("type hash mismatch for {s}: expected 0x{x:0>16}, got 0x{x:0>16}", .{
                @typeName(T),
                comptime hashType(T),
                actual_hash,
            });
            return error.TypeMismatch;
        }
    }

    return try deserializeValue(ara, src, T);
}

pub const DeserializeError = std.mem.Allocator.Error || error{
    BufferTooSmall,
    InvalidUnionTag,
    InvalidByte,
    InvalidError,
    AllocationRequired,
    InvalidHeader,
    TypeMismatch,
};

fn deserialize_error_set(src: *[]const u8, comptime E: type) DeserializeError!struct { err: E } {
    const l = log(.zoto);
    return if (@typeInfo(E).error_set.error_names) |fields| blk: {
        const name = try deserializeValue(null, src, []const u8);
        break :blk inline for (fields) |f| {
            if (std.mem.eql(u8, name, f))
                break .{ .err = @field(E, f) };
        } else {
            l.err("unknown error '{s}' for {s}", .{ name, @typeName(E) });
            break :blk error.InvalidError;
        };
    } else .{ .err = @errorFromInt(try readInt(src, u16)) };
}

fn deserializeValue(ara: ?std.mem.Allocator, src: *[]const u8, comptime T: type) DeserializeError!T {
    const l = log(.zoto);
    switch (@typeInfo(T)) {
        inline .int => return try readInt(src, T),
        inline .float => |f| {
            const IntT = comptime @Int(.unsigned, f.bits);
            const raw_bits = try readInt(src, IntT);
            return @bitCast(raw_bits);
        },

        inline .bool => {
            const val = try readByte(src);
            return if (val == std.math.maxInt(u8))
                true
            else if (val == std.math.minInt(u8))
                false
            else {
                l.err("invalid bool byte 0x{x:0>2}", .{val});
                return error.InvalidByte;
            };
        },

        inline .optional => |o| {
            const has_value = try readByte(src);
            return if (has_value == std.math.maxInt(u8))
                if (comptime @typeInfo(o.child) == .error_set)
                    @as(T, (try deserialize_error_set(src, o.child)).err)
                else
                    try deserializeValue(ara, src, o.child)
            else if (has_value == std.math.minInt(u8))
                null
            else {
                l.err("invalid optional byte 0x{x:0>2} for {s}", .{ has_value, @typeName(T) });
                return error.InvalidByte;
            };
        },

        inline .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.field_names, s.field_types) |f_name, f_type|
                @field(result, f_name) = if (comptime @typeInfo(f_type) == .error_set)
                    (try deserialize_error_set(src, f_type)).err
                else
                    try deserializeValue(ara, src, f_type);
            return result;
        },

        inline .@"enum" => return @fromBackingInt(try readInt(src, std.meta.BackingInt(T))),
        inline .@"union" => |u| {
            const tag_id = try readByte(src);
            const tag_type = u.tag_type orelse @compileError("Union must be tagged for zoto: " ++ @typeName(T));

            inline for (u.field_names, u.field_types) |f_name, f_type|
                if (@backingInt(@field(tag_type, f_name)) == tag_id)
                    return @unionInit(
                        T,
                        f_name,
                        if (comptime @typeInfo(f_type) == .error_set)
                            (try deserialize_error_set(src, f_type)).err
                        else
                            try deserializeValue(ara, src, f_type),
                    );

            l.err("invalid union tag {d} for {s}", .{ tag_id, @typeName(T) });
            return error.InvalidUnionTag;
        },

        inline .pointer => |p| switch (p.size) {
            inline .slice => {
                const len = try readInt(src, u64);
                if (p.child == u8)
                    return try readSlice(src, len)
                else if (ara) |alloc_| {
                    var slice = try alloc_.alloc(p.child, len);
                    errdefer alloc_.free(slice);

                    for (0..len) |i|
                        slice[i] = if (comptime @typeInfo(p.child) == .error_set)
                            (try deserialize_error_set(src, p.child)).err
                        else
                            try deserializeValue(ara, src, p.child);

                    return slice;
                } else if (comptime !hasPointers(p.child)) {
                    const raw_bytes = try readSlice(src, len * @sizeOf(p.child));
                    const typed_ptr: [*]const p.child = @ptrCast(@alignCast(raw_bytes.ptr));
                    return @constCast(typed_ptr[0..len]);
                } else {
                    l.err("allocator required to deserialize {s}", .{@typeName(T)});
                    return error.AllocationRequired;
                }
            },
            inline .one => {
                if (ara) |alloc_| {
                    const ptr = try alloc_.create(p.child);
                    errdefer alloc_.destroy(ptr);

                    ptr.* = if (comptime @typeInfo(p.child) == .error_set)
                        (try deserialize_error_set(src, p.child)).err
                    else
                        try deserializeValue(ara, src, p.child);
                    return ptr;
                } else if (comptime !hasPointers(p.child)) {
                    const raw_bytes = try readSlice(src, @sizeOf(p.child));
                    return @as(*const p.child, @ptrCast(@alignCast(raw_bytes.ptr)));
                } else {
                    l.err("allocator required to deserialize {s}", .{@typeName(T)});
                    return error.AllocationRequired;
                }
            },
            else => @compileError("Unsupported pointer size for zoto: " ++ @typeName(T)),
        },

        inline .array => |a| {
            var arr: T = undefined;
            for (0..a.len) |i| {
                arr[i] = if (comptime @typeInfo(a.child) == .error_set)
                    (try deserialize_error_set(src, a.child)).err
                else
                    try deserializeValue(ara, src, a.child);
            }
            return arr;
        },

        inline .error_union => |eu| {
            const is_payload = try readByte(src);
            return if (is_payload == 1)
                @as(T, try deserializeValue(ara, src, eu.payload))
            else if (is_payload == 0)
                @as(T, (try deserialize_error_set(src, eu.error_set)).err)
            else {
                l.err("invalid error_union byte 0x{x:0>2} for {s}", .{ is_payload, @typeName(T) });
                return error.InvalidByte;
            };
        },

        inline .void => return {},
        else => @compileError("Unsupported type for zoto deserialization: " ++ @typeName(T)),
    }
}

fn hasPointers(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .pointer, .error_set, .error_union => true,
        .@"struct" => |s| inline for (s.field_types) |f_type| {
            if (hasPointers(f_type))
                break true;
        } else false,
        .@"union" => |u| inline for (u.field_types) |f_type| {
            if (hasPointers(f_type))
                break true;
        } else false,
        .optional => |o| hasPointers(o.child),
        .array => |a| hasPointers(a.child),
        else => false,
    };
}

fn writeByte(buf: *[]u8, byte: u8) !void {
    if (buf.len < 1)
        return error.BufferTooSmall;
    buf.*[0] = byte;
    buf.* = buf.*[1..];
}

fn readByte(src: *[]const u8) !u8 {
    if (src.len < 1)
        return error.BufferTooSmall;
    const b = src.*[0];
    src.* = src.*[1..];
    return b;
}

fn readSlice(src: *[]const u8, len: usize) ![]const u8 {
    if (src.len < len)
        return error.BufferTooSmall;
    const s = src.*[0..len];
    src.* = src.*[len..];
    return s;
}

fn readInt(src: *[]const u8, comptime IntT: type) !IntT {
    const Int = comptime @typeInfo(IntT).int;
    const size = comptime @divCeil(Int.bits, 8);
    const I = comptime @Int(Int.signedness, size * 8);
    if (src.len < size)
        return error.BufferTooSmall;
    const val = std.mem.readInt(I, src.*[0..size], .little);
    src.* = src.*[size..];
    return @truncate(val);
}
fn writeInt(w: *std.Io.Writer, comptime IntT: type, val: IntT) !void {
    const Int = comptime @typeInfo(IntT).int;
    const I = comptime @Int(Int.signedness, @divCeil(Int.bits, 8) * 8);
    const i: I = @intCast(val);
    try w.writeInt(I, i, endian);
}
