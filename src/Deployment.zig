const std = @import("std");

pub const Service = @import("Service.zig");
pub const Workspace = @import("Workspace.zig");
pub const Target = @import("Target.zig");
const Project = @import("Project.zig");
const UUIDv7 = @import("UUIDv7.zig");
const install = @import("install.zig");

uuid: UUIDv7,

service: Service,

artifacts: []Artifact = &.{},
running: []Running = &.{},
targets: []Target = &.{},

pub const Running = struct {
    remote: ?[]const u8,
    pipeline: []const u8,
};

pub const Artifact = union(enum) {
    src: struct {
        consumed: bool = false,
    },
    build: struct {
        remote: ?[]const u8,
        pipeline: []const u8,
        exit_code: u8,
    },
};

pub fn create(alloc: std.mem.Allocator, io: std.Io, service: Service, targets: []Target) !@This() {
    const id = try UUIDv7.new(io);

    const src = try alloc.alloc(Artifact, 1);
    src[0] = .{ .src = .{} };

    return .{
        .uuid = id,
        .service = service,
        .artifacts = src,
        .running = &.{},
        .targets = targets,
    };
}

pub fn save(self: @This(), io: std.Io, proj: *const Project) !void {
    var buffer: [1 << 10]u8 = undefined;
    var pos: []u8 = &buffer;
    var filename = try self.uuid.to_string(pos);
    std.mem.copyForwards(u8, pos[filename.len .. filename.len + 4], ".zon");
    filename = pos[0 .. filename.len + 4];
    pos = pos[filename.len + 4 ..];

    const deployments_dir = try proj.open_deployments_dir(io);
    defer deployments_dir.close(io);
    var atomic = try deployments_dir.createFileAtomic(io, filename, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    var writer = atomic.file.writer(io, pos);
    try std.zon.stringify.serializeArbitraryDepth(self, .{}, &writer.interface);
    try writer.flush();
    try atomic.replace(io);
}
