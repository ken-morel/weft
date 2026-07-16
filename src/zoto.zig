//! Compact, zero-copy binary serialization engine for Zig.
//!
//! ## Overview
//! `zoto` serializes Zig values into a contiguous byte buffer and deserializes
//! them back. Strings (`[]const u8`) and byte slices point directly into the input
//! buffer without copying memory.
//!
//! ## Wire Format
//! All data is encoded in Little-Endian format.
//!
//! 1. **Header (12 Bytes):**
//!    - Magic Magic String: `"ZOTO"` (4 bytes)
//!    - Type Hash: `u64` (8 bytes) — Comptime FNV-1a structural hash of type `T`.
//!
//! 2. **Payload:**
//!    - **Primitives (`int`, `float`, `bool`):** Stored in exact size/endianness.
//!    - **Optionals (`?T`):** `1` byte flag (`0x00` = null, `0x01` = value) + payload if present.
//!    - **Tagged Unions:** `1` byte tag integer + active field payload.
//!    - **Slices (`[]T`):** `u64` length prefix + array of serialized items.
//!    - **Arrays (`[N]T`):** Serialized elements sequentially (0 byte overhead).
//!    - **Single Pointers (`*T`):** Serialized as the dereferenced pointee value `T`.
//!
//! ## Memory & Allocator Modes
//! - **Zero-Allocation Mode (`allocator = null`):** Deserializes flat structs, primitives,
//!   arrays, optionals, unions, and 1D byte slices (`[]const u8`) without allocating RAM.
//! - **Hybrid Zero-Copy Mode (`allocator = gpa`):** Required for nested dynamic slices
//!   (e.g., `[][]const u8`) or single heap pointers (`*T`). Allocates array headers in RAM
//!   while keeping underlying string bytes zero-copy from the input buffer.
//!
//! ## Critical Notices
//! 1. **Self-Referencing / Infinite Types:** Do not pass recursive graph types (e.g. linked
//!    lists `Node = struct { next: ?*Node }`). Dereferencing will cause infinite loops at comptime
//!    or runtime. Use flat arrays with integer index references instead.
//! 2. **Stdlib Collections:** Do not serialize types like `std.HashMap` directly.
//!    Convert them to slices of key-value structs prior to passing them to `zoto`.
//! 3. **Alignment:** On strict-alignment architectures (e.g. ARM Cortex-M0), zero-copying
//!    scalar slices (`[]const u32`) requires the input buffer to be aligned to `@alignOf(T)`.

const std = @import("std");

/// Calculates a structural 64-bit hash at compile time for a given type `T`.
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

            .enumeration => |e| {
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

// ============================================================================
// SERIALIZATION
// ============================================================================

/// Serializes `value` into `dest` including the "ZOTO" header and type hash.
/// Returns a slice of `dest` containing only the written payload bytes.
pub fn serialize(dest: []u8, value: anytype) ![]u8 {
    const T = @TypeOf(value);
    var cursor = dest;

    try writeBytes(&cursor, "ZOTO");
    try writeInt(&cursor, u64, comptime hashType(T));
    try serializeValue(&cursor, value);

    const bytes_written = dest.len - cursor.len;
    return dest[0..bytes_written];
}

/// Recursively serializes values into a slice cursor without a header.
pub fn serializeValue(cursor: *[]u8, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        inline .int => try writeInt(cursor, T, value),
        inline .float => |f| {
            const IntT = std.meta.Int(.unsigned, f.bits);
            try writeInt(cursor, IntT, @bitCast(value));
        },

        inline .bool => try writeByte(cursor, if (value) 1 else 0),
        inline .optional => {
            if (value) |payload| {
                try writeByte(cursor, 1);
                try serializeValue(cursor, payload);
            } else {
                try writeByte(cursor, 0);
            }
        },

        inline .@"struct" => |s| {
            inline for (s.fields) |f| {
                try serializeValue(cursor, @field(value, f.name));
            }
        },

        inline .enumeration => try serializeValue(cursor, @intFromEnum(value)),

        inline .@"union" => {
            const tag = std.meta.activeTag(value);
            try writeByte(cursor, @intFromEnum(tag));
            switch (value) {
                inline else => |payload| try serializeValue(cursor, payload),
            }
        },

        inline .pointer => |p| {
            switch (p.size) {
                .Slice => {
                    try writeInt(cursor, u64, value.len);
                    for (value) |item| {
                        try serializeValue(cursor, item);
                    }
                },
                .One => {
                    // Dereference pointer and serialize pointee value directly
                    try serializeValue(cursor, value.*);
                },
                else => @compileError("Unsupported pointer size for zoto: " ++ @typeName(T)),
            }
        },

        inline .array => {
            for (value) |item| {
                try serializeValue(cursor, item);
            }
        },

        inline .void => {},
        else => @compileError("Unsupported type for zoto serialization: " ++ @typeName(T)),
    }
}

// ============================================================================
// DESERIALIZATION
// ============================================================================

/// Reads and verifies the "ZOTO" header and type hash.
/// Advanced the `src` slice cursor as bytes are read.
pub fn deserialize(allocator: ?std.mem.Allocator, src: *[]const u8, comptime T: type) !T {
    const header = try readSlice(src, 4);
    if (!std.mem.eql(u8, header, "ZOTO")) {
        return error.InvalidHeader;
    }

    const expected_hash = comptime hashType(T);
    const actual_hash = try readInt(src, u64);
    if (expected_hash != actual_hash) {
        return error.TypeMismatch;
    }

    return try deserializeValue(allocator, src, T);
}

/// Recursively deserializes values from a slice cursor without header validation.
pub fn deserializeValue(allocator: ?std.mem.Allocator, src: *[]const u8, comptime T: type) !T {
    const info = @typeInfo(T);

    switch (info) {
        .int => return try readInt(src, T),

        .float => |f| {
            const IntT = std.meta.Int(.unsigned, f.bits);
            const raw_bits = try readInt(src, IntT);
            return @bitCast(raw_bits);
        },

        .bool => return (try readByte(src)) != 0,

        .optional => |o| {
            const has_value = try readByte(src);
            if (has_value == 1) {
                return try deserializeValue(allocator, src, o.child);
            } else {
                return null;
            }
        },

        .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.fields) |f| {
                @field(result, f.name) = try deserializeValue(allocator, src, f.type);
            }
            return result;
        },

        .enumeration => |e| {
            const raw_val = try deserializeValue(allocator, src, e.tag_type);
            return @enumFromInt(raw_val);
        },

        .@"union" => |u| {
            const tag_id = try readByte(src);
            const tag_type = u.tag_type orelse @compileError("Union must be tagged for zoto: " ++ @typeName(T));

            inline for (u.fields) |f| {
                if (@intFromEnum(@field(tag_type, f.name)) == tag_id) {
                    const payload = try deserializeValue(allocator, src, f.type);
                    return @unionInit(T, f.name, payload);
                }
            }
            return error.InvalidUnionTag;
        },

        .pointer => |p| {
            switch (p.size) {
                .Slice => {
                    const len = try readInt(src, u64);

                    // 1. Strings/byte slices are ALWAYS zero-copy
                    if (p.child == u8) {
                        return try readSlice(src, len);
                    }

                    // 2. Allocator mode for nested dynamic slices
                    if (allocator) |alloc| {
                        var slice = try alloc.alloc(p.child, len);
                        errdefer alloc.free(slice);

                        for (0..len) |i| {
                            slice[i] = try deserializeValue(allocator, src, p.child);
                        }
                        return slice;
                    }

                    // 3. Zero-allocation mode for flat scalar slices
                    if (comptime !hasPointers(p.child)) {
                        const needed_bytes = len * @sizeOf(p.child);
                        const raw_bytes = try readSlice(src, needed_bytes);
                        const typed_ptr: [*]const p.child = @ptrCast(@alignCast(raw_bytes.ptr));
                        return typed_ptr[0..len];
                    }

                    return error.AllocationRequired;
                },
                .One => {
                    // Single pointers dereference on serialize, but require allocation on deserialize
                    if (allocator) |alloc| {
                        const ptr = try alloc.create(p.child);
                        errdefer alloc.destroy(ptr);

                        ptr.* = try deserializeValue(allocator, src, p.child);
                        return ptr;
                    }
                    return error.AllocationRequired;
                },
                else => @compileError("Unsupported pointer size for zoto: " ++ @typeName(T)),
            }
        },

        .array => |a| {
            var arr: T = undefined;
            for (0..a.len) |i| {
                arr[i] = try deserializeValue(allocator, src, a.child);
            }
            return arr;
        },

        .void => return {},
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

fn writeByte(cursor: *[]u8, byte: u8) !void {
    if (cursor.len < 1) return error.BufferTooSmall;
    cursor.*[0] = byte;
    cursor.* = cursor.*[1..];
}

fn writeBytes(cursor: *[]u8, bytes: []const u8) !void {
    if (cursor.len < bytes.len) return error.BufferTooSmall;
    @memcpy(cursor.*[0..bytes.len], bytes);
    cursor.* = cursor.*[bytes.len..];
}

fn writeInt(cursor: *[]u8, comptime IntT: type, value: IntT) !void {
    const size = @sizeOf(IntT);
    if (cursor.len < size) return error.BufferTooSmall;
    std.mem.writeInt(IntT, cursor.*[0..size], value, .little);
    cursor.* = cursor.*[size..];
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

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "zoto: single pointer support" {
    const val: u32 = 1234;
    const Item = struct {
        ptr: *const u32,
    };

    const original = Item{ .ptr = &val };
    var buf: [64]u8 = undefined;

    const encoded = try serialize(&buf, original);

    var reader = encoded;
    const decoded = try deserialize(testing.allocator, &reader, Item);
    defer testing.allocator.destroy(decoded.ptr);

    try testing.expectEqual(original.ptr.*, decoded.ptr.*);
}

test "zoto: zero-allocation mode (null allocator)" {
    const FlatConfig = struct {
        id: u32,
        name: []const u8,
        active: bool,
    };

    const original = FlatConfig{ .id = 42, .name = "ZeroAlloc", .active = true };
    var buf: [128]u8 = undefined;

    const encoded = try serialize(&buf, original);

    // Pass null for allocator -> 100% Zero-Allocation
    var reader = encoded;
    const decoded = try deserialize(null, &reader, FlatConfig);

    try testing.expectEqual(original.id, decoded.id);
    try testing.expectEqualSlices(u8, original.name, decoded.name);
}

test "zoto: hybrid mode with nested string slices" {
    const Config = struct {
        runtimes: [][]const u8, // Nested string slice
    };

    const runtimes_list = [_][]const u8{ "node:20", "python:3.11", "bun:1.0" };
    const original = Config{ .runtimes = &runtimes_list };

    var buf: [256]u8 = undefined;
    const encoded = try serialize(&buf, original);

    // Pass arena allocator for the array headers
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var reader = encoded;
    const decoded = try deserialize(arena.allocator(), &reader, Config);

    try testing.expectEqual(3, decoded.runtimes.len);

    // Prove string bytes are STILL zero-copy from the original encoded slice!
    const buf_start = @intFromPtr(&buf[0]);
    const buf_end = buf_start + buf.len;
    const str0_ptr = @intFromPtr(decoded.runtimes[0].ptr);

    try testing.expect(str0_ptr >= buf_start and str0_ptr < buf_end);
    try testing.expectEqualSlices(u8, "node:20", decoded.runtimes[0]);
}

test "zoto: error when nested slice is deserialized with null allocator" {
    const Nested = struct {
        tags: [][]const u8,
    };

    const tags_list = [_][]const u8{"test"};
    const original = Nested{ .tags = &tags_list };

    var buf: [64]u8 = undefined;
    const encoded = try serialize(&buf, original);

    // null allocator on nested slice returns AllocationRequired
    var reader = encoded;
    const err = deserialize(null, &reader, Nested);

    try testing.expectError(error.AllocationRequired, err);
}
