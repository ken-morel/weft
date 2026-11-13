const std = @import("std");

const Project = @import("../client/Project.zig");
const Server = @import("../daemon/Server.zig");
const proto = @import("../domain/proto.zig");
const Weft = @import("../domain/Weft.zig");
pub const Connection = @import("../wire/Connection.zig");
const Crypt = @import("../wire/Crypt.zig");
const Identity = @import("../wire/Identity.zig");
const Nonce = @import("../wire/Nonce.zig");
const ClientInstall = @import("ClientInstall.zig");
const Remote = @import("Remote.zig");

const Client = @This();

pub const Transport = union(enum) {
    net: struct {
        stream: std.Io.net.Stream,
        reader: std.Io.net.Stream.Reader,
        writer: std.Io.net.Stream.Writer,
    },
    stdio: struct {
        child: std.process.Child,
        reader: std.Io.File.Reader,
        writer: std.Io.File.Writer,
    },
};

conn: Connection,
buffer: []u8,
transport: Transport,

fn create_take(gpa: std.mem.Allocator, io: std.Io, transport: Transport, identity: Identity) !*@This() {
    const self = try gpa.create(@This());
    errdefer gpa.destroy(self);
    const buffer = try gpa.alloc(u8, 8 << 10);
    errdefer gpa.free(buffer);

    self.transport = transport;
    self.buffer = buffer;

    const reader_buf = buffer[0 .. buffer.len / 2];
    const writer_buf = buffer[buffer.len / 2 ..];

    const reader, const writer = switch (self.transport) {
        .net => |*n| n: {
            n.reader = n.stream.reader(io, reader_buf);
            n.writer = n.stream.writer(io, writer_buf);
            break :n .{ &n.reader.interface, &n.writer.interface };
        },
        .stdio => |*s| s: {
            n: {
                s.reader = (s.child.stdout orelse unreachable).reader(io, reader_buf);
                s.writer = (s.child.stdin orelse unreachable).writer(io, writer_buf);
                break :n;
            }
            break :s .{ &s.reader.interface, &s.writer.interface };
        },
    };

    const temp_dh = std.crypto.dh.X25519.KeyPair.generate(io);
    const out_nonce = try Nonce.random(io);

    const hello: Crypt.ClientHello = .{
        .client_public = identity.public_key(),
        .client_temp_pub = temp_dh.public_key,
        .client_nonce = out_nonce.to_bytes(),
    };

    try writer.writeAll(std.mem.asBytes(&hello));
    try writer.flush();

    var challenge_msg: Crypt.ServerChallenge = undefined;
    try reader.readSliceAll(std.mem.asBytes(&challenge_msg));
    switch (challenge_msg.status) {
        .ok => {},
        .unauthorized => return error.ClientUnauthorized,
        .proto_mismatch => return error.ProtocolMismatch,
    }

    const sign_data = Crypt.make_sign_data(&challenge_msg.challenge, &challenge_msg.server_temp_pub);
    const sig = try identity.sign(&sign_data);

    const auth: Crypt.ClientAuth = .{
        .signature = sig.toBytes(),
    };
    try writer.writeAll(std.mem.asBytes(&auth));
    try writer.flush();

    const shared_secret = try std.crypto.dh.X25519.scalarmult(
        temp_dh.secret_key,
        challenge_msg.server_temp_pub,
    );

    var in_nonce_bytes = challenge_msg.server_nonce;
    const in_nonce = try Nonce.from_bytes(&in_nonce_bytes);

    self.conn = .{
        .reader = reader,
        .writer = writer,
        .write_crypt = .init(&shared_secret, out_nonce),
        .read_crypt = .init(&shared_secret, in_nonce),
    };
    return self;
}

fn connect(gpa: std.mem.Allocator, io: std.Io, addr: Remote.Address, identity: Identity, env: ?*std.process.Environ.Map) !*@This() {
    const transport: Transport = transport: switch (addr) {
        .provided => return error.UnresolvedAddress,
        .stdio => |cmd| {
            if (cmd.len == 0)
                return error.EmptyCommand;

            const child = try std.process.spawn(io, .{
                .argv = cmd,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
                .environ_map = env,
            });
            break :transport .{
                .stdio = .{
                    .child = child,
                    .reader = undefined,
                    .writer = undefined,
                },
            };
        },
        .ip => |ip| {
            const stream = try ip.connect(io, .{
                .mode = .stream,
                .protocol = .tcp,
            });
            break :transport .{
                .net = .{
                    .stream = stream,
                    .reader = undefined,
                    .writer = undefined,
                },
            };
        },
    };
    errdefer switch (transport) {
        .stdio => |s| {
            var child = s.child;
            child.kill(io);
        },
        .net => |n| n.stream.close(io),
    };
    return try create_take(gpa, io, transport, identity);
}

pub fn destroy(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
    switch (self.transport) {
        .net => |*n| n.stream.close(io),
        .stdio => |*s| s.child.kill(io),
    }
    alloc.free(self.buffer);
    alloc.destroy(self);
}

pub const Managed = struct {
    bounded: bool,
    address: Remote.Address,
    inner: *Client,
    manager: *Manager,
    lock: std.Io.Mutex,

    pub fn release(self: *@This(), io: std.Io) void {
        if (self.bounded)
            self.lock.unlock(io)
        else {
            const gpa = self.manager.gpa;
            self.address.deinit(gpa);
            self.inner.destroy(gpa, io);
            gpa.destroy(self);
        }
    }
};

const Provider = struct {
    arena: std.heap.ArenaAllocator,
    cmd: []const []const u8,
    child: std.process.Child,
    resolved: Remote.Address,
};

const max_resolve_depth = 8;

pub const Manager = struct {
    clients: std.ArrayList(*Managed),
    lock: std.Io.Mutex,
    providers: std.ArrayList(*Provider),
    provider_lock: std.Io.Mutex,

    gpa: std.mem.Allocator,
    identity: Identity,
    env: ?*std.process.Environ.Map,
    inst: ?ClientInstall = null,
    project: ?Project = null,

    pub fn create(gpa: std.mem.Allocator, identity: Identity, env: ?*std.process.Environ.Map) !*@This() {
        const self = try gpa.create(@This());
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .clients = .empty,
            .lock = .init,
            .providers = .empty,
            .provider_lock = .init,
            .identity = identity,
            .env = env,
        };
        return self;
    }

    pub inline fn connect_nonblocking(self: *@This(), io: std.Io, addr: Remote.Address) !?*Managed {
        return try _connect(self, io, addr, false);
    }
    pub inline fn connect_blocking(self: *@This(), io: std.Io, addr: Remote.Address) !*Managed {
        return try _connect(self, io, addr, true) orelse unreachable;
    }

    fn _connect(self: *@This(), io: std.Io, addr: Remote.Address, block: bool) !?*Managed {
        var current = addr;
        const resolved: Remote.Address = for (0..max_resolve_depth) |_| {
            switch (current) {
                .provided => |cmd| current = try self.resolve_provided(io, cmd),
                .ip, .stdio => break current,
            }
        } else {
            std.log.scoped(.client_connect).err("remote address resolution is more than {d} levels deep", .{max_resolve_depth});
            return error.AddressResolutionTooDeep;
        };
        return try self.connect_resolved(io, resolved, block);
    }

    fn resolve_provided(self: *@This(), io: std.Io, cmd: []const []const u8) !Remote.Address {
        const l = std.log.scoped(.client_provider);
        try self.provider_lock.lock(io);
        defer self.provider_lock.unlock(io);

        const provider: *Provider = for (self.providers.items) |p| {
            if (Remote.Address.cmd_eql(p.cmd, cmd))
                break p;
        } else provider: {
            if (cmd.len == 0)
                return error.EmptyCommand;

            const new_provider = try self.gpa.create(Provider);
            errdefer self.gpa.destroy(new_provider);
            new_provider.arena = .init(self.gpa);
            errdefer new_provider.arena.deinit();
            const ara = new_provider.arena.allocator();

            new_provider.cmd = try Remote.Address.dupe_cmd(ara, cmd);
            new_provider.child = try std.process.spawn(io, .{
                .argv = new_provider.cmd,
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .inherit,
                .environ_map = self.env,
            });
            errdefer new_provider.child.kill(io);

            var buf: [1 << 9]u8 = undefined;
            var reader = (new_provider.child.stdout orelse unreachable).reader(io, &buf);
            const line = reader.interface.takeDelimiterExclusive(
                '\n',
            ) catch |err| {
                l.err("address provider '{s}' did not print an address on its first line: {any}", .{ cmd[0], err });
                return error.ProviderNoAddress;
            };
            const addr_str = std.mem.trim(u8, line, " \t\r");
            l.debug("address provider '{s}' returned '{s}'", .{ cmd[0], addr_str }); //debug

            new_provider.resolved = try Remote.Address.resolve_leaky(ara, ara, io, addr_str, self.inst, self.project);
            try self.providers.append(self.gpa, new_provider);
            break :provider new_provider;
        };
        return provider.resolved;
    }

    fn connect_resolved(self: *@This(), io: std.Io, addr: Remote.Address, block: bool) !?*Managed {
        try self.lock.lock(io);
        if (addr == .stdio) {
            for (self.clients.items) |m|
                if (m.address.cmp(addr)) {
                    self.lock.unlock(io);
                    if (block) {
                        try m.lock.lock(io);
                        return m;
                    } else return if (m.lock.tryLock())
                        m
                    else
                        null;
                };
        }
        defer self.lock.unlock(io);

        const client: *Client = try Client.connect(
            self.gpa,
            io,
            addr,
            self.identity,
            self.env,
        );
        errdefer client.destroy(self.gpa, io);

        const addr_clone = try addr.dupe(self.gpa);
        errdefer addr_clone.deinit(self.gpa);

        const managed = try self.gpa.create(Managed);
        errdefer self.gpa.destroy(managed);

        const bounded = addr == .stdio;
        managed.* = .{
            .address = addr_clone,
            .inner = client,
            .manager = self,
            .lock = .init,
            .bounded = bounded,
        };

        managed.lock.lockUncancelable(io);
        if (bounded)
            try self.clients.append(self.gpa, managed);
        return managed;
    }

    pub fn connect_str(self: *@This(), io: std.Io, addr_str: []const u8) !*Managed {
        const addr = try Weft.RemoteAddress.parse(self.gpa, io, addr_str);
        defer addr.deinit(self.gpa);
        return try self.connect_blocking(io, addr);
    }

    pub fn destroy(self: *@This(), io: std.Io) void {
        for (self.clients.items) |m| {
            m.address.deinit(self.gpa);
            m.inner.destroy(self.gpa, io);
            self.gpa.destroy(m);
        }
        self.clients.deinit(self.gpa);
        for (self.providers.items) |p| {
            p.child.kill(io);
            p.arena.deinit();
            self.gpa.destroy(p);
        }
        self.providers.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};
