const std = @import("std");

const Pressor = @import("../Pressor.zig");

io: std.Io,
output: []u8,
pressor: Pressor,
lock: std.Io.Mutex,

pub fn init(alloc: std.mem.Allocator, io: std.Io) !@This() {
    const output = try alloc.alloc(u8, Pressor.max_uncompressed_size);
    const buffer = try alloc.alloc(u8, Pressor.buffer_size);
    return .{
        .io = io,
        .output = output,
        .pressor = .init(buffer),
        .lock = .init,
    };
}

pub fn acquire(self: *@This()) !*@This() {
    try self.lock.lock(self.io);
    return self;
}
pub fn try_acquire(self: *@This()) ?*@This() {
    return if (self.lock.tryLock())
        self
    else
        null;
}

pub fn release(self: *@This()) void {
    self.lock.unlock(self.io);
}

pub fn compress(self: *@This(), input: *std.Io.Reader) ![]u8 {
    switch (self.lock.state.raw) {
        .unlocked => @panic("Manged Compressor not acquired"),
        else => {},
    }
    var writer: std.Io.Writer = .fixed(self.output);
    try self.pressor.compress(input, &writer);
    return writer.buffered();
}
pub fn decompress(self: *@This(), input: *std.Io.Reader) ![]u8 {
    switch (self.lock.state.raw) {
        .unlocked => @panic("Manged Compressor not acquired"),
        else => {},
    }
    var writer: std.Io.Writer = .fixed(self.output);
    try self.pressor.decompress(input, &writer);
    return writer.buffered();
}

pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
    alloc.free(self.output);
    alloc.free(self.pressor.buffer);
}
