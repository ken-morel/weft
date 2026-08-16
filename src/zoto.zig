const std = @import("std");

pub fn hashType(comptime T: type) u64 {
    comptime {
        var h: u64 = 14695981039346656037;
        const prime = 1099511628211;

        const info = @typeInfo(T);

        for (@tagName(info)) |char| h = (h ^ char) *% prime;

        switch (info) {
            .void => {},
            .bool => h = (h ^ @as(u64, 1)) *% prime,

            .int => |i| {
                h = (h ^ i.bits) *% prime;
                h = (h ^ @intFromEnum(i.signedness)) *% prime;
            },

            .float => |f| {
                h = (f.bits ^ h) *% prime;
            },

            .@"struct" => |s| {
                for (s.fields) |f| {
                    for (f.name) |char| h = (h ^ char) *% prime;
                    h = (h ^ hashType(f.type)) *% prime;
                }
            },

            .@"union" => |u| {
                if (u.tag_type) |tt| h = (h ^ hashType(tt)) *% prime;
                for (u.fields) |f| {
                    for (f.name) |char| h = (h ^ char) *% prime;
                    h = (h ^ hashType(f.type)) *% prime;
                }
            },

            .@"enum" => |e| {
                h = (h ^ hashType(e.tag_type)) *% prime;
                for (e.fields) |f| {
                    for (f.name) |char| h = (h ^ char) *% prime;
                    h = (h ^ @as(u64, f.value)) *% prime;
                }
            },

            .pointer => |p| {
                h = (h ^ @intFromEnum(p.size)) *% prime;
                h = (h ^ @as(u64, if (p.is_const) 1 else 0)) *% prime;
                for (@typeName(p.child)) |char| h = (h ^ char) *% prime;
            },

            .array => |a| {
                h = (h ^ a.len) *% prime;
                h = (h ^ hashType(a.child)) *% prime;
            },

            .optional => |o| {
                h = (h ^ 0xBEEF) *% prime;
                h = (h ^ hashType(o.child)) *% prime;
            },

            else => @compileError("Zoto does not support hashing type: " ++ @typeName(T)),
        }
        return h;
    }
}

pub fn serialize(dest: *[]u8, value: anytype) !void {
    const T = @TypeOf(value);

    try writeBytes(dest, "ZOTO");
    try writeInt(dest, u64, comptime hashType(T));
    try serializeValue(dest, value);
}

pub fn serializeValue(ptr: *[]u8, value: anytype) error{BufferTooSmall}!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        inline .int => try writeInt(ptr, T, value),
        inline .float => |f| try writeInt(
            ptr,
            std.meta.Int(.unsigned, f.bits),
            @bitCast(value),
        ),

        inline .bool => try writeByte(ptr, if (value) 1 else 0),
        inline .optional => if (value) |payload| {
            try writeByte(ptr, 1);
            try serializeValue(ptr, payload);
        } else try writeByte(ptr, 0),
        inline .@"struct" => |s| {
            inline for (s.fields) |f|
                try serializeValue(
                    ptr,
                    @field(value, f.name),
                );
        },
        inline .@"enum" => try serializeValue(ptr, @intFromEnum(value)),
        inline .@"union" => {
            try writeByte(ptr, @intFromEnum(std.meta.activeTag(value)));
            switch (value) {
                inline else => |payload| try serializeValue(
                    ptr,
                    payload,
                ),
            }
        },
        inline .pointer => |p| switch (p.size) {
            inline .slice => {
                try writeInt(ptr, u64, value.len);
                for (value) |item| // just put inline everywhere
                    try serializeValue(ptr, item);
            },
            inline .one => try serializeValue(ptr, value.*),
            inline else => @compileError("Unsupported pointer size for zoto: " ++ @typeName(T)),
        },
        inline .array => for (value) |item|
            try serializeValue(ptr, item),
        inline .error_set => try writeInt(ptr, u16, @intFromError(value)),
        inline .void => {},
        else => @compileError("Unsupported type for zoto serialization: " ++ @typeName(T)),
    }
}

pub fn deserialize(allocator: ?std.mem.Allocator, src: *[]const u8, comptime T: type) !T {
    const header = try readSlice(src, 4);
    if (!std.mem.eql(u8, header, "ZOTO"))
        return error.InvalidHeader;

    const actual_hash = try readInt(src, u64);
    if (actual_hash != comptime hashType(T))
        return error.TypeMismatch;

    return try deserializeValue(allocator, src, T);
}

pub const DeserializeError = std.mem.Allocator.Error || error{
    BufferTooSmall,
    InvalidUnionTag,
    AllocationRequired,
    InvalidHeader,
    TypeMismatch,
};

pub fn deserializeValue(allocator: ?std.mem.Allocator, src: *[]const u8, comptime T: type) DeserializeError!T {
    const info = @typeInfo(T);

    switch (info) {
        inline .int => return try readInt(src, T),

        inline .float => |f| {
            const IntT = comptime std.meta.Int(.unsigned, f.bits);
            const raw_bits = try readInt(src, IntT);
            return @bitCast(raw_bits);
        },

        inline .bool => return (try readByte(src)) != 0,

        inline .optional => |o| {
            const has_value = try readByte(src);
            if (has_value == 1)
                return try deserializeValue(allocator, src, o.child)
            else
                return null;
        },

        inline .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.fields) |f|
                @field(result, f.name) = try deserializeValue(allocator, src, f.type);
            return result;
        },

        inline .@"enum" => |e| return @enumFromInt(try deserializeValue(allocator, src, e.tag_type)),

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
                            try deserializeValue(allocator, src, f.type),
                    );

            return error.InvalidUnionTag;
        },

        inline .pointer => |p| switch (p.size) {
            inline .slice => {
                const len = try readInt(src, u64);

                // u8 are always aligned and thus zero-copy easily
                if (p.child == u8)
                    return try readSlice(src, len)
                else if (allocator) |alloc| {
                    var slice = try alloc.alloc(p.child, len);
                    errdefer alloc.free(slice);

                    for (0..len) |i|
                        slice[i] = try deserializeValue(allocator, src, p.child);

                    return slice;
                } else if (comptime !hasPointers(p.child)) {
                    const raw_bytes = try readSlice(src, len * @sizeOf(p.child));
                    const typed_ptr: [*]const p.child = @ptrCast(@alignCast(raw_bytes.ptr));
                    return @constCast(typed_ptr[0..len]);
                }

                return error.AllocationRequired;
            },
            inline .one => {
                // Single pointers dereference on serialize, but require allocation on deserialize
                if (allocator) |alloc| {
                    const ptr = try alloc.create(p.child);
                    errdefer alloc.destroy(ptr);

                    ptr.* = try deserializeValue(allocator, src, p.child);
                    return ptr;
                } else if (comptime !hasPointers(p.child)) { //BUG: check this
                    const raw_bytes = try readSlice(src, @sizeOf(p.child));
                    return @as(*const p.child, @ptrCast(@alignCast(raw_bytes.ptr)));
                }
                return error.AllocationRequired;
            },
            else => @compileError("Unsupported pointer size for zoto: " ++ @typeName(T)),
        },

        inline .array => |a| {
            var arr: T = undefined;
            for (0..a.len) |i| {
                arr[i] = try deserializeValue(allocator, src, a.child);
            }
            return arr;
        },

        inline .error_set => return @errorFromInt(try readInt(src, u16)),

        inline .void => return {},
        else => @compileError("Unsupported type for zoto deserialization: " ++ @typeName(T)),
    }
}

// ============================================================================
// HELPER UTILITIES
// ============================================================================

fn hasPointers(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => true,
        .@"struct" => |s| inline for (s.fields) |f| {
            if (hasPointers(f.type)) break true;
        } else false,
        .@"union" => |u| inline for (u.fields) |f| {
            if (hasPointers(f.type)) break true;
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

fn writeBytes(cursor: *[]u8, bytes: []const u8) !void {
    if (cursor.len < bytes.len) return error.BufferTooSmall;
    @memcpy(cursor.*[0..bytes.len], bytes);
    cursor.* = cursor.*[bytes.len..];
}

fn writeInt(buffer: *[]u8, comptime IntT: type, value: IntT) !void {
    const size = @sizeOf(IntT);
    if (buffer.len < size)
        return error.BufferTooSmall;
    std.mem.writeInt(IntT, buffer.*[0..size], value, .little);
    buffer.* = buffer.*[size..];
}

fn readByte(src: *[]const u8) !u8 {
    if (src.len < 1) return error.BufferTooSmall;
    const b = src.*[0];
    src.* = src.*[1..];
    return b;
}

fn readSlice(src: *[]const u8, len: usize) ![]const u8 {
    if (src.len < len) return error.BufferTooSmall;
    const s = src.*[0..len];
    src.* = src.*[len..];
    return s;
}

fn readInt(src: *[]const u8, comptime IntT: type) !IntT {
    const size = @sizeOf(IntT);
    if (src.len < size) return error.BufferTooSmall;
    const val = std.mem.readInt(IntT, src.*[0..size], .little);
    src.* = src.*[size..];
    return val;
}
