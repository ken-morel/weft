const std = @import("std");

pub const weft_path = "/var/lib/weft/";
pub const weft_cache_path = "/var/cache/weft/";
pub const weft_artifacts_dir = weft_path ++ "artifacts/";
pub const weft_run_dir = weft_path ++ "run/";
pub const weft_archive = weft_path ++ "archive/";
pub const weft_keep_dir = weft_path ++ "keep/";
pub const weft_home_dir = weft_path ++ "home/";
pub const weft_tmp_dir = weft_path ++ "tmp/";
pub const weft_store_dir = weft_path ++ "store/";
pub const weft_bin_dir = weft_path ++ "bin/";

pub const weft_runtime_dir = "/run/weft/";
pub const weft_socket = weft_runtime_dir ++ "weft.pipe";

pub const weft_nix_path = weft_path ++ "nix/";
pub const weft_nix_store_path = weft_nix_path ++ "store/";
pub const weft_nix_nar_path = weft_nix_path ++ "nar/";
pub const weft_nix_narinfo_path = weft_nix_path ++ "narinfo/";
pub const weft_nix_store_lock_path = weft_nix_store_path ++ ".lock";

pub const weft_config_path = "/etc/weft";

pub fn ensure_dirs(io: std.Io) !void {
    const cwd: std.Io.Dir = .cwd();
    try cwd.createDirPath(io, weft_artifacts_dir);
    try cwd.createDirPath(io, weft_run_dir);
    try cwd.createDirPath(io, weft_archive);
    try cwd.createDirPath(io, weft_keep_dir);
    try cwd.createDirPath(io, weft_home_dir);
    try cwd.createDirPath(io, weft_tmp_dir);
    try cwd.createDirPath(io, weft_store_dir);
    try cwd.createDirPath(io, weft_bin_dir);

    try cwd.createDirPath(io, weft_runtime_dir);

    try cwd.createDirPath(io, weft_nix_store_path);
    try cwd.createDirPath(io, weft_nix_nar_path);
    try cwd.createDirPath(io, weft_nix_narinfo_path);
    try cwd.createDirPath(io, weft_nix_store_lock_path);
}

pub inline fn home(gpa: std.mem.Allocator, w: []const u8) ![]u8 {
    return try std.fs.path.join(
        gpa,
        &.{ weft_home_dir, w },
    );
}

pub inline fn artifact(
    gpa: std.mem.Allocator,
    w: []const u8,
    d: []const u8,
    p: []const u8,
) ![]u8 {
    return try std.fs.path.join(
        gpa,
        &.{ weft_artifacts_dir, w, d, p },
    );
}
pub inline fn artifacts(
    gpa: std.mem.Allocator,
    w: []const u8,
    d: []const u8,
) ![]u8 {
    return try std.fs.path.join(
        gpa,
        &.{ weft_artifacts_dir, w, d },
    );
}

pub inline fn run(
    gpa: std.mem.Allocator,
    w: []const u8,
    p: []const u8,
    d: []const u8,
) ![]u8 {
    return try std.fs.path.join(
        gpa,
        &.{ weft_run_dir, w, p, d },
    );
}

pub inline fn task_archive(
    gpa: std.mem.Allocator,
    w: []const u8,
    d: []const u8,
    p: []const u8,
) ![]const u8 {
    return try std.fs.path.join(
        gpa,
        &.{ weft_archive, w, d, p },
    );
}

pub inline fn task_cache(
    gpa: std.mem.Allocator,
    w: []const u8,
    k: []const u8,
) ![]const u8 {
    return try std.fs.path.join(
        gpa,
        &.{ weft_keep_dir, w, k },
    );
}
pub inline fn temp_dir(
    gpa: std.mem.Allocator,
    reg: []const u8,
    key: []const u8,
) ![]const u8 {
    return try std.fs.path.join(
        gpa,
        &.{ weft_tmp_dir, reg, key },
    );
}

pub inline fn store(
    gpa: std.mem.Allocator,
    s: []const u8,
) ![]const u8 {
    return try std.fs.path.join(
        gpa,
        &.{ weft_store_dir, s },
    );
}

pub inline fn nix_to_weft_store(
    gpa: std.mem.Allocator,
    s: []const u8,
) ![]const u8 {
    return try std.fs.path.join(
        gpa,
        &.{ weft_store_dir, s[0..11] },
    );
}

pub const read_only_user_permissions = @as(std.Io.File.Permissions, @fromBackingInt(@intCast(@as(u32, std.os.linux.S.IRUSR | std.os.linux.S.IWUSR))));
