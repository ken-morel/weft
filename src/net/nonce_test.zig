const std = @import("std");
const testing = std.testing;
const Nonce = @import("Nonce.zig");

test "initialization and zero" {
    const id1 = Nonce.init(0x1234_5678_9ABC_DEF0_1234_5678_9ABC_DEF0);
    try testing.expectEqual(@as(u128, 0x1234_5678_9ABC_DEF0_1234_5678_9ABC_DEF0), id1.base);
    try testing.expectEqual(@as(u64, 0), id1.counter);

    const id_zero = Nonce.zero();
    try testing.expectEqual(@as(u128, 0), id_zero.base);
    try testing.expectEqual(@as(u64, 0), id_zero.counter);
}

test "increment counter" {
    var id = Nonce.init(42);
    try testing.expectEqual(@as(u64, 0), id.counter);

    id.inc();
    try testing.expectEqual(@as(u64, 1), id.counter);

    id.inc();
    try testing.expectEqual(@as(u64, 2), id.counter);

    // Base should remain unchanged
    try testing.expectEqual(@as(u128, 42), id.base);
}

test "to_bytes and from_bytes roundtrip" {
    var id = Nonce.init(0xDEAD_BEEF_CAFE_BABE_0011_2233_4455_6677);
    id.inc();
    id.inc(); // counter is now 2

    const bytes = id.to_bytes();
    try testing.expectEqual(24, bytes.len);

    var mut_bytes = bytes;
    const restored = try Nonce.from_bytes(&mut_bytes);

    try testing.expectEqual(id.base, restored.base);
    try testing.expectEqual(id.counter, restored.counter);
}

test "explicit byte layout endianness check" {
    // Test base = 0x01, counter = 0x02
    const id = .{ .base = 1, .counter = 2 };
    const bytes = id.to_bytes();

    // Verify Little Endian order for base (bytes 0..16)
    try testing.expectEqual(@as(u8, 1), bytes[0]);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 15, bytes[1..16]);

    // Verify Little Endian order for counter (bytes 16..24)
    try testing.expectEqual(@as(u8, 2), bytes[16]);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 7, bytes[17..24]);
}

test "from_bytes invalid slice size error" {
    var short_bytes = [_]u8{0} ** 23;
    var long_bytes = [_]u8{0} ** 25;

    try testing.expectError(error.InvalidSize, Nonce.from_bytes(&short_bytes));
    try testing.expectError(error.InvalidSize, Nonce.from_bytes(&long_bytes));
}

test "read and write streams" {
    var id = Nonce.init(0x112233445566778899AABBCCDDEEFF00);
    id.inc();

    var buffer: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);

    // Test writing to stream
    try id.write(fbs.writer());

    // Verify 24 bytes were written
    try testing.expectEqual(@as(usize, 24), fbs.pos);

    // Reset stream position to start reading
    fbs.pos = 0;
    const read_id = try Nonce.read(fbs.reader());

    try testing.expectEqual(id.base, read_id.base);
    try testing.expectEqual(id.counter, read_id.counter);
}
