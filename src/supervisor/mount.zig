const std = @import("std");
const linux = std.os.linux;

pub const Ms = packed struct(u32) {
    read_only: bool = false,
    no_suid: bool = false,
    no_dev: bool = false,
    no_exec: bool = false,
    _a: u10 = 0,
    rec: bool = false,
    _b: u3 = 0,
    private: bool = false,
    _c: u13 = 0,
};

pub const OPEN_TREE = struct {
    pub const CLONE: u32 = 1 << 0;
    pub const CLOEXEC: u32 = @backingInt(linux.O{ .CLOEXEC = true });
};

pub const MOVE_MOUNT = struct {
    pub const F_EMPTY_PATH: u32 = 0x04;
};

pub const MountAttrFlag = packed struct(u64) {
    read_only: bool = false,
    no_suid: bool = false,
    no_dev: bool = false,
    no_exec: bool = false,
    _a: u60 = 0,
};

pub const MountAttr = extern struct {
    attr_set: MountAttrFlag = .{},
    attr_clr: MountAttrFlag = .{},
    propagation: u64 = 0,
    userns_fd: u64 = 0,
};

pub const BindOpts = struct {
    read_only: bool = true,
    allow_exec: bool = false,
    allow_dev: bool = false,
};

pub fn isolate() !void {
    const rc = linux.mount(
        "none",
        "/",
        null,
        @backingInt(Ms{
            .rec = true,
            .private = true,
        }),
        0,
    );
    if (linux.errno(rc) != .SUCCESS)
        return error.MountFailed;
}

pub fn mount_fs(src: [:0]const u8, target: [:0]const u8, fstype: [:0]const u8, options: ?[:0]const u8, allow_exec: bool) !void {
    const rc = linux.mount(
        src.ptr,
        target.ptr,
        fstype.ptr,
        @backingInt(Ms{
            .no_suid = true,
            .no_dev = true,
            .no_exec = !allow_exec,
        }),
        if (options) |o| @intFromPtr(o.ptr) else 0,
    );
    if (linux.errno(rc) != .SUCCESS)
        return error.MountFailed;
}

pub fn bind(source: [:0]const u8, target: [:0]const u8, opts: BindOpts) !void {
    const tree_rc = linux.syscall3(
        .open_tree,
        @bitCast(@as(isize, linux.AT.FDCWD)),
        @intFromPtr(source.ptr),
        OPEN_TREE.CLONE | OPEN_TREE.CLOEXEC | linux.AT.RECURSIVE,
    );
    if (linux.errno(tree_rc) != .SUCCESS)
        return error.OpenTreeFailed;

    const tree_fd: linux.fd_t = @intCast(tree_rc);
    defer _ = linux.close(tree_fd);

    var attr: MountAttr = .{
        .attr_set = .{
            .no_suid = true,
        },
    };
    if (opts.read_only)
        attr.attr_set.read_only = true;
    if (!opts.allow_exec)
        attr.attr_set.no_exec = true;
    if (!opts.allow_dev)
        attr.attr_set.no_dev = true;

    const setattr_rc = linux.syscall5(
        .mount_setattr,
        @intCast(tree_fd),
        @intFromPtr(""),
        linux.AT.EMPTY_PATH | linux.AT.RECURSIVE,
        @intFromPtr(&attr),
        @sizeOf(MountAttr),
    );
    if (linux.errno(setattr_rc) != .SUCCESS)
        return error.MountSetAttrFailed;

    const move_rc = linux.syscall5(
        .move_mount,
        @intCast(tree_fd),
        @intFromPtr(""),
        @bitCast(@as(isize, linux.AT.FDCWD)),
        @intFromPtr(target.ptr),
        MOVE_MOUNT.F_EMPTY_PATH,
    );
    if (linux.errno(move_rc) != .SUCCESS)
        return error.MoveMountFailed;
}

pub fn lock_read_only(target_mount_path: [:0]const u8) !void {
    var attr: MountAttr = .{
        .attr_set = .{
            .read_only = true,
            .no_suid = true,
            .no_dev = true,
        },
    };
    // Note: AT.RECURSIVE is intentionally omitted so child mounts (/work, /out/{name}) stay RW.
    const rc = linux.syscall5(
        .mount_setattr,
        @bitCast(@as(isize, linux.AT.FDCWD)),
        @intFromPtr(target_mount_path.ptr),
        linux.AT.SYMLINK_NOFOLLOW,
        @intFromPtr(&attr),
        @sizeOf(MountAttr),
    );
    if (linux.errno(rc) != .SUCCESS)
        return error.LockReadOnlyFailed;
}

pub fn pivot_root(new_root: [:0]const u8) !void {
    if (linux.errno(linux.chdir(new_root.ptr)) != .SUCCESS)
        return error.ChdirFailed;

    const pivot_rc = linux.syscall2(.pivot_root, @intFromPtr("."), @intFromPtr("."));
    if (linux.errno(pivot_rc) != .SUCCESS)
        return error.PivotRootFailed;

    const umount_rc = linux.umount2(".", linux.MNT.DETACH);
    if (linux.errno(umount_rc) != .SUCCESS)
        return error.UmountOldRootFailed;
    if (linux.errno(linux.chdir("/")) != .SUCCESS)
        return error.ChdirRootFailed;
}
