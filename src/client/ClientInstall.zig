const std = @import("std");
const builtin = @import("builtin");

const build = @import("build");

const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const Identity = @import("../wire/Identity.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");

pub const key_file_name = "key";

pub const Remote = struct {
    []const u8,
    []const u8,
};

pub const Config = struct {
    remotes: []const Remote = &.{},
};

config_dir: std.Io.Dir,
data_dir: std.Io.Dir,
temp_dir: std.Io.Dir,
identity: Identity,
env: *const std.process.Environ.Map,

pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !@This() {
    const config_dir = try open_config_dir(gpa, io, env);
    const data_dir = try open_data_dir(gpa, io, env);

    try data_dir.createDirPath(io, "temp");
    const temp_dir = try data_dir.openDir(io, "temp", .{ .iterate = true });

    const identity = try Identity.ensure(io, config_dir, key_file_name);

    return .{
        .config_dir = config_dir,
        .data_dir = data_dir,
        .temp_dir = temp_dir,
        .identity = identity,
        .env = env,
    };
}

pub fn read_config_leaky(self: @This(), gpa: std.mem.Allocator, ara: std.mem.Allocator, io: std.Io) !Config {
    const content = self.config_dir.readFileAllocOptions(io, "client.zon", ara, .unlimited, .of(u8), 0) catch |e| blk: {
        if (e == error.FileNotFound) {
            break :blk self.config_dir.readFileAllocOptions(io, "config.zon", ara, .unlimited, .of(u8), 0) catch |err| {
                if (err == error.FileNotFound)
                    return .{};
                return err;
            };
        }
        return e;
    };
    var diag: std.zon.parse.Diagnostics = .{ .errors = &.{undefined} };
    return std.zon.parse.fromSlice(Config, .{
        .arena = ara,
        .gpa = gpa,
        .source = content,
        .diagnostics = &diag,
    }) catch |err| {
        if (err == error.ParseZon)
            diag.log("client.zon");
        return err;
    };
}

pub fn locate_script(self: @This(), gpa: std.mem.Allocator, io: std.Io, name: []const u8) !?[:0]const u8 {
    return Project.locate_script_in_dir(io, self.config_dir, gpa, name);
}
pub fn open_temp(self: @This(), io: std.Io, sub: []const u8) !std.Io.Dir {
    const uuid = (try Deployment.Id.now(io)).to_string();

    self.temp_dir.createDirPath(io, sub) catch {};
    var sub_dir = try self.temp_dir.openDir(io, sub, .{});
    defer sub_dir.close(io);

    try sub_dir.createDirPath(io, &uuid);
    return try sub_dir.openDir(io, &uuid, .{});
}

pub fn open_config_dir(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !std.Io.Dir {
    const path = path: {
        if (builtin.os.tag == .windows) {
            if (env.get("APPDATA")) |appdata| {
                const path = try std.fs.path.join(gpa, &.{ appdata, build.app_id });
                break :path path;
            } else {
                return error.NoAppData;
            }
        } else {
            const path = try if (env.get("XDG_CONFIG_HOME")) |xdg|
                std.fs.path.join(gpa, &.{ xdg, "weft" })
            else if (env.get("HOME")) |home|
                std.fs.path.join(gpa, &.{ home, ".config", "weft" })
            else
                return error.NoHomeFound;
            break :path path;
        }
    };
    defer gpa.free(path);
    return try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
}

pub fn open_data_dir(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !std.Io.Dir {
    const path = path: {
        if (builtin.os.tag == .windows) {
            if (env.get("LOCALAPPDATA")) |appdata| {
                const path = try std.fs.path.join(gpa, &.{ appdata, build.app_id });
                break :path path;
            } else {
                return error.NoAppData;
            }
        } else {
            break :path try if (env.get("HOME")) |home|
                std.fs.path.join(gpa, &.{ home, ".weft" })
            else
                return error.NoHomeFound;
        }
    };

    defer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}
