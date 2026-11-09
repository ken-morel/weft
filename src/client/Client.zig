const std = @import("std");

const Project = @import("../client/Project.zig");
const Server = @import("../daemon/Server.zig");
const proto = @import("../domain/proto.zig");
const Weft = @import("../domain/Weft.zig");
pub const Connection = @import("../wire/Connection.zig");
const Crypt = @import("../wire/Crypt.zig");
const Identity = @import("../wire/Identity.zig");
const Nonce = @import("../wire/Nonce.zig");

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

fn connect(gpa: std.mem.Allocator, io: std.Io, project: ?Project, addr: Weft.RemoteAddress, identity: Identity, env: ?*std.process.Environ.Map) !*@This() {
    const transport: Transport = transport: switch (addr) {
        .cmd => |cmd| if (project) |p| {
            if (cmd.len == 0)
                return error.EmptyCommand;
            var argv = try gpa.dupe([]const u8, cmd);
            defer gpa.free(argv);
            const script = try p.locate_script(gpa, io, cmd[0]) orelse return error.ScriptNotFound;
            defer gpa.free(script);
            argv[0] = script;

            const child = try std.process.spawn(io, .{
                .argv = argv,
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
        } else return error.ExpectedProject,
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
    return try create_take(gpa, io, transport, identity);
}

pub fn destroy(self: *@This(), alloc: std.mem.Allocator, io: std.Io) void {
    switch (self.transport) {
        .net => |*n| n.stream.close(io),
        .stdio => |*s| {
            if (s.child.stdin) |*f|
                f.close(io);
            if (s.child.stdout) |*f|
                f.close(io);
            s.child.kill(io);
            _ = s.child.wait(io) catch {};
        },
    }
    alloc.free(self.buffer);
    alloc.destroy(self);
}

pub const Managed = struct {
    bounded: bool,
    address: Weft.RemoteAddress,
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

pub const Manager = struct {
    clients: std.ArrayList(*Managed),
    lock: std.Io.Mutex,
    project: ?Project,
    gpa: std.mem.Allocator,
    identity: Identity,
    env: ?*std.process.Environ.Map,

    pub fn create(gpa: std.mem.Allocator, project: ?Project, identity: Identity, env: ?*std.process.Environ.Map) !*@This() {
        const self = try gpa.create(@This());
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .clients = .empty,
            .lock = .init,
            .project = project,
            .identity = identity,
            .env = env,
        };
        return self;
    }

    pub fn connect(self: *@This(), io: std.Io, addr: Weft.RemoteAddress) !*Managed {
        try self.lock.lock(io);
        if (std.meta.activeTag(addr) == .cmd) {
            for (self.clients.items) |m|
                if (m.address.cmp(addr)) {
                    self.lock.unlock(io);
                    try m.lock.lock(io);
                    return m;
                };
        }
        defer self.lock.unlock(io);

        const client: *Client = try Client.connect(
            self.gpa,
            io,
            self.project,
            addr,
            self.identity,
            self.env,
        );
        errdefer client.destroy(self.gpa, io);

        const addr_clone = try addr.dupe(self.gpa);
        errdefer addr_clone.deinit(self.gpa);

        const managed = try self.gpa.create(Managed);
        errdefer self.gpa.destroy(managed);

        const bounded = std.meta.activeTag(addr) == .cmd;
        managed.* = .{
            .address = addr_clone,
            .inner = client,
            .manager = self,
            .lock = .init,
            .bounded = bounded,
        };

        try managed.lock.lock(io);
        if (bounded) {
            try self.clients.append(self.gpa, managed);
            return managed;
        } else return managed;
    }

    pub fn connect_str(self: *@This(), io: std.Io, addr_str: []const u8) !*Managed {
        const addr = try Weft.RemoteAddress.parse(self.gpa, io, addr_str);
        defer addr.deinit(self.gpa);
        return try self.connect(io, addr);
    }

    pub fn destroy(self: *@This(), io: std.Io) void {
        for (self.clients.items) |m| {
            m.address.deinit(self.gpa);
            m.inner.destroy(self.gpa, io);
            self.gpa.destroy(m);
        }
        self.clients.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};
