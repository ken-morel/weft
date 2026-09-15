const std = @import("std");

const endian: std.builtin.Endian = .little;

/// Serialization and deserialization options
pub const Options = struct {
    /// The serialized data contains a heder
    header: bool = false,
    /// Specify an integer type to use it as integer size for the hash,
    /// or null if you don't want a type hash
    hash: ?type = u64,
};

/// Get a hash of type T, the hash is a u64 truncated to type I
pub fn hashType(comptime T: type, comptime I: type) I {
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
            h = (h ^ @intFromEnum(i.signedness)) *% prime;
        },
        .float => |f| h = (f.bits ^ h) *% prime,
        .@"struct" => |s| {
            for (s.fields) |f| {
                for (f.name) |char|
                    h = (h ^ char) *% prime;
                h = (h ^ hashType(f.type, u64)) *% prime;
            }
        },

        .@"union" => |u| {
            if (u.tag_type) |tt|
                h = (h ^ hashType(tt, u64)) *% prime;
            for (u.fields) |f| {
                for (f.name) |char|
                    h = (h ^ char) *% prime;
                h = (h ^ hashType(f.type, u64)) *% prime;
            }
        },

        .@"enum" => |e| {
            h = (h ^ hashType(e.tag_type, u64)) *% prime;
            for (e.fields) |f| {
                for (f.name) |char|
                    h = (h ^ char) *% prime;
                h = (h ^ @as(u64, f.value)) *% prime;
            }
        },

        .pointer => |p| {
            h = (h ^ @intFromEnum(p.size)) *% prime;
            h = (h ^ @as(u64, if (p.is_const) 1 else 0)) *% prime;
            for (@typeName(p.child)) |char|
                h = (h ^ char) *% prime;
        },

        .array => |a| {
            h = (h ^ a.len) *% prime;
            h = (h ^ hashType(a.child, u64)) *% prime;
        },

        .optional => |o| {
            h = (h ^ 0xBEEF) *% prime;
            h = (h ^ hashType(o.child, u64)) *% prime;
        },

        .error_set => |es| if (es) |fields| {
            h = (h ^ 0xBAEF) *% prime;
            for (fields) |f| {
                for (f.name) |char|
                    h = (h ^ char) *% prime;
            }
        },

        .error_union => |eu| {
            h = (h ^ hashType(eu.error_set, u64)) *% prime;
            h = (h ^ hashType(eu.payload, u64)) *% prime;
        },

        else => @compileError("Zoto does not support hashing type: " ++ @typeName(T)),
    }
    return @truncate(h);
}

pub fn serialize(writer: *std.Io.Writer, comptime T: type, value: T, comptime opts: Options) std.Io.Writer.Error!void {
    if (opts.header)
        try writer.writeAll("ZOTO");
    if (opts.hash) |I|
        try writer.writeInt(I, comptime hashType(T, I), endian);
    try serializeValue(writer, T, value);
}

fn serializeValue(writer: *std.Io.Writer, comptime T: type, value: T) std.Io.Writer.Error!void {
    const info = @typeInfo(T);

    switch (info) {
        inline .int => try writer.writeInt(T, value, endian),
        inline .float => |f| try writer.writeInt(
            std.meta.Int(.unsigned, f.bits),
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
            inline for (s.fields) |f|
                try serializeValue(
                    writer,
                    f.type,
                    @field(value, f.name),
                );
        },
        inline .@"enum" => try writer.writeByte(@intCast(@intFromEnum(value))),
        inline .@"union" => {
            try writer.writeByte(@intCast(@intFromEnum(std.meta.activeTag(value))));
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
        inline .error_set => try serializeValue(writer, u16, @intFromError(value)),
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

pub fn deserialize(alloc: ?std.mem.Allocator, src: *[]const u8, comptime T: type, opts: Options) DeserializeError!T {
    if (opts.header) {
        const header = try readSlice(src, 4);
        if (!std.mem.eql(u8, header, "ZOTO"))
            return error.InvalidHeader;
    }

    if (opts.hash) |I| {
        const actual_hash = try readInt(src, I);
        if (actual_hash != comptime hashType(T, I))
            return error.TypeMismatch;
    }

    return try deserializeValue(alloc, src, T);
}

pub const DeserializeError = std.mem.Allocator.Error || error{
    BufferTooSmall,
    InvalidUnionTag,
    InvalidByte,
    AllocationRequired,
    InvalidHeader,
    TypeMismatch,
};

fn deserializeValue(alloc: ?std.mem.Allocator, src: *[]const u8, comptime T: type) DeserializeError!T {
    switch (@typeInfo(T)) {
        inline .int => return try readInt(src, T),
        inline .float => |f| {
            const IntT = comptime std.meta.Int(.unsigned, f.bits);
            const raw_bits = try readInt(src, IntT);
            return @bitCast(raw_bits);
        },

        inline .bool => {
            const val = try readByte(src);
            return if (val == std.math.maxInt(u8))
                true
            else if (val == std.math.minInt(u8))
                false
            else
                error.InvalidByte;
        },

        inline .optional => |o| {
            const has_value = try readByte(src);
            return if (has_value == std.math.maxInt(u8))
                try deserializeValue(alloc, src, o.child)
            else if (has_value == std.math.minInt(u8))
                null
            else
                error.InvalidByte;
        },

        inline .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.fields) |f|
                @field(result, f.name) = try deserializeValue(alloc, src, f.type);
            return result;
        },

        inline .@"enum" => return @enumFromInt(try readByte(src)),

        inline .@"union" => |u| {
            const tag_id = try readByte(src);
            const tag_type = u.tag_type orelse @compileError("Union must be tagged for zoto: " ++ @typeName(T));

            inline for (u.fields) |f|
                if (@intFromEnum(@field(tag_type, f.name)) == tag_id)
                    return @unionInit(
                        T,
                        f.name,
                        if (comptime f.type == anyerror)
                            @errorFromInt(try readInt(src, u16))
                        else
                            try deserializeValue(alloc, src, f.type),
                    );

            return error.InvalidUnionTag;
        },

        inline .pointer => |p| switch (p.size) {
            inline .slice => {
                const len = try readInt(src, u64);

                // u8 are always aligned and thus zero-copy easily
                if (p.child == u8)
                    return try readSlice(src, len)
                else if (alloc) |alloc_| {
                    var slice = try alloc_.alloc(p.child, len);
                    errdefer alloc_.free(slice);

                    for (0..len) |i|
                        slice[i] = try deserializeValue(alloc, src, p.child);

                    return slice;
                } else if (comptime !hasPointers(p.child)) {
                    const raw_bytes = try readSlice(src, len * @sizeOf(p.child));
                    const typed_ptr: [*]const p.child = @ptrCast(@alignCast(raw_bytes.ptr));
                    return @constCast(typed_ptr[0..len]);
                } else return error.AllocationRequired;
            },
            inline .one => {
                if (alloc) |alloc_| {
                    const ptr = try alloc_.create(p.child);
                    errdefer alloc_.destroy(ptr);

                    ptr.* = try deserializeValue(alloc, src, p.child);
                    return ptr;
                } else if (comptime !hasPointers(p.child)) { //BUG: check this
                    const raw_bytes = try readSlice(src, @sizeOf(p.child));
                    return @as(*const p.child, @ptrCast(@alignCast(raw_bytes.ptr)));
                } else return error.AllocationRequired;
            },
            else => @compileError("Unsupported pointer size for zoto: " ++ @typeName(T)),
        },

        inline .array => |a| {
            var arr: T = undefined;
            for (0..a.len) |i| {
                arr[i] = try deserializeValue(alloc, src, a.child);
            }
            return arr;
        },

        inline .error_set => {
            const err: T = @errorCast(@errorFromInt(try readInt(src, u16)));
            return err;
        },

        inline .error_union => |eu| {
            const is_payload = try readByte(src);
            if (is_payload != 0)
                return try deserializeValue(alloc, src, eu.payload);
            const err: eu.error_set = @errorCast(@errorFromInt(try readInt(src, u16)));
            return @as(T, err);
        },

        inline .void => return {},
        else => @compileError("Unsupported type for zoto deserialization: " ++ @typeName(T)),
    }
}

fn hasPointers(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => true,
        .@"struct" => |s| inline for (s.fields) |f| {
            if (hasPointers(f.type))
                break true;
        } else false,
        .@"union" => |u| inline for (u.fields) |f| {
            if (hasPointers(f.type))
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
    const size = @sizeOf(IntT);
    if (src.len < size)
        return error.BufferTooSmall;
    const val = std.mem.readInt(IntT, src.*[0..size], .little);
    src.* = src.*[size..];
    return val;
}
