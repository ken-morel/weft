const std = @import("std");
const testing = std.testing;

// Import your module files
const Connection = @import("Connection.zig").Connection;
const Message = @import("Connection.zig").Message;
const Nonce = @import("Nonce.zig");

const SECRET_KEY: [32]u8 = [_]u8{0x42} ** 32;

// ============================================================================
// TEST 1: Basic TCP Handshake & Single Message Exchange
// ============================================================================

test "Connection: TCP Handshake and basic Message exchange" {
    const allocator = testing.allocator;

    // 1. Setup local TCP listener on OS-assigned port (port 0)
    var listener = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try listener.listen(.{ .reuse_address = true });
    defer server.deinit();

    const server_addr = server.listen_address;

    // Context passed to client thread
    const ClientCtx = struct {
        addr: std.net.Address,
        alloc: std.mem.Allocator,

        fn run(ctx: @This()) !void {
            var stream = try std.net.tcpConnectToAddress(ctx.addr);
            defer stream.close();

            // Perform Connection Handshake
            var secret = SECRET_KEY;
            var conn = try Connection.init(
                ctx.alloc,
                undefined, // Pass your std.Io or mock context if required by Nonce
                &secret,
                stream.reader(),
                stream.writer(),
            );
            defer conn.deinit(ctx.alloc);

            // Send request
            const msg = Message{ .data = "hello server" };
            try conn.send(msg);

            // Read response
            var arena = std.heap.ArenaAllocator.init(ctx.alloc);
            defer arena.deinit();

            const response = try conn.recv(&arena);
            try testing.expectEqualSlices(u8, "hello server", response.bytes);
        }
    };

    // 2. Spawn Client Thread
    const client_thread = try std.Thread.spawn(.{}, ClientCtx.run, .{ClientCtx{
        .addr = server_addr,
        .alloc = allocator,
    }});

    // 3. Accept Server Connection
    var server_stream = try server.accept();
    defer server_stream.stream.close();

    var secret = SECRET_KEY;
    var server_conn = try Connection.init(
        allocator,
        undefined,
        &secret,
        server_stream.stream.reader(),
        server_stream.stream.writer(),
    );
    defer server_conn.deinit(allocator);

    // Read client message
    var server_arena = std.heap.ArenaAllocator.init(allocator);
    defer server_arena.deinit();

    const client_msg = try server_conn.recv(&server_arena);
    try testing.expectEqualSlices(u8, "hello server", client_msg.bytes);

    // Echo back
    try server_conn.send(client_msg);

    // Wait for client to finish
    client_thread.join();
}

// ============================================================================
// TEST 2: Echo Server Stress Test (500 Sequential Messages & Union Variants)
// ============================================================================

test "Connection: Stress Echo Test across multiple Message variants" {
    const allocator = testing.allocator;

    var listener = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try listener.listen(.{ .reuse_address = true });
    defer server.deinit();

    const MESSAGE_COUNT: usize = 200;

    const ClientRunner = struct {
        addr: std.net.Address,
        alloc: std.mem.Allocator,

        fn run(ctx: @This()) !void {
            var stream = try std.net.tcpConnectToAddress(ctx.addr);
            defer stream.close();

            var secret = SECRET_KEY;
            var conn = try Connection.init(
                ctx.alloc,
                undefined,
                &secret,
                stream.reader(),
                stream.writer(),
            );
            defer conn.deinit(ctx.alloc);

            var arena = std.heap.ArenaAllocator.init(ctx.alloc);
            defer arena.deinit();

            for (0..MESSAGE_COUNT) |i| {
                _ = arena.reset(.retain_capacity);

                // Alternating message types to stress zoto serializer over TCP
                const msg_to_send: Message = if (i % 3 == 0)
                    Message{ .request = .workspace_sync }
                else if (i % 3 == 1)
                    Message{ .file = .{ .path = "/etc/config.json", .size = @intCast(i * 1024) } }
                else
                    Message{ .ok = {} };

                try conn.send(msg_to_send);

                const echo = try conn.recv(&arena);
                switch (msg_to_send) {
                    .request => try testing.expectEqual(Message.request.workspace_sync, echo.request),
                    .file => |f| try testing.expectEqual(f.size, echo.file.size),
                    .ok => try testing.expectEqual({}, echo.ok),
                    else => unreachable,
                }
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, ClientRunner.run, .{ClientRunner{
        .addr = server.listen_address,
        .alloc = allocator,
    }});

    var server_stream = try server.accept();
    defer server_stream.stream.close();

    var secret = SECRET_KEY;
    var server_conn = try Connection.init(
        allocator,
        undefined,
        &secret,
        server_stream.stream.reader(),
        server_stream.stream.writer(),
    );
    defer server_conn.deinit(allocator);

    var server_arena = std.heap.ArenaAllocator.init(allocator);
    defer server_arena.deinit();

    for (0..MESSAGE_COUNT) |_| {
        _ = server_arena.reset(.retain_capacity);
        const msg = try server_conn.recv(&server_arena);
        try server_conn.send(msg);
    }

    thread.join();
}

// ============================================================================
// TEST 3: TCP Fragmentation / Chunked Stream Assembly
// ============================================================================

test "Connection: TCP Fragmentation and Packet Boundaries" {
    const allocator = testing.allocator;

    var listener = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try listener.listen(.{ .reuse_address = true });
    defer server.deinit();

    const FragmentClient = struct {
        addr: std.net.Address,
        alloc: std.mem.Allocator,

        fn run(ctx: @This()) !void {
            var stream = try std.net.tcpConnectToAddress(ctx.addr);
            defer stream.close();

            var secret = SECRET_KEY;
            var conn = try Connection.init(
                ctx.alloc,
                undefined,
                &secret,
                stream.reader(),
                stream.writer(),
            );
            defer conn.deinit(ctx.alloc);

            // Send a large message (~8KB)
            const large_payload = try ctx.alloc.alloc(u8, 8192);
            defer ctx.alloc.free(large_payload);
            @memset(large_payload, 0xAB);

            try conn.send(Message{ .data = large_payload });
        }
    };

    const thread = try std.Thread.spawn(.{}, FragmentClient.run, .{FragmentClient{
        .addr = server.listen_address,
        .alloc = allocator,
    }});

    var server_stream = try server.accept();
    defer server_stream.stream.close();

    var secret = SECRET_KEY;
    var server_conn = try Connection.init(
        allocator,
        undefined,
        &secret,
        server_stream.stream.reader(),
        server_stream.stream.writer(),
    );
    defer server_conn.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Read back fragmented data
    const msg = try server_conn.recv(&arena);
    try testing.expectEqual(@as(usize, 8192), msg.bytes.len);
    try testing.expectEqual(@as(u8, 0xAB), msg.bytes[0]);

    thread.join();
}

// ============================================================================
// TEST 4: AEAD Auth Tag Corruption (Security Test)
// ============================================================================

test "Connection: Tampered Ciphertext or Auth Tag Rejection" {
    const allocator = testing.allocator;

    var listener = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try listener.listen(.{ .reuse_address = true });
    defer server.deinit();

    const TamperClient = struct {
        addr: std.net.Address,
        alloc: std.mem.Allocator,

        fn run(ctx: @This()) !void {
            var stream = try std.net.tcpConnectToAddress(ctx.addr);
            defer stream.close();

            var secret = SECRET_KEY;
            var conn = try Connection.init(
                ctx.alloc,
                undefined,
                &secret,
                stream.reader(),
                stream.writer(),
            );
            defer conn.deinit(ctx.alloc);

            // Send normal message
            try conn.send(Message{ .data = "Secret Payload" });
        }
    };

    const thread = try std.Thread.spawn(.{}, TamperClient.run, .{TamperClient{
        .addr = server.listen_address,
        .alloc = allocator,
    }});

    var server_stream = try server.accept();
    defer server_stream.stream.close();

    var secret = SECRET_KEY;
    var server_conn = try Connection.init(
        allocator,
        undefined,
        &secret,
        server_stream.stream.reader(),
        server_stream.stream.writer(),
    );
    defer server_conn.deinit(allocator);

    // Intentionally corrupt the key token in memory on the receiver side
    server_conn.token[0] ^= 0xFF;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Recv should fail with AuthenticationFailed error from XChaCha20Poly1305
    const result = server_conn.recv(&arena);
    try testing.expectError(error.AuthenticationFailed, result);

    thread.join();
}
