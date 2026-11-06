const std = @import("std");
const linux = std.os.linux;

pub const CLONE = struct {
    pub const NEWNS: u32 = 0x00020000;
    pub const NEWCGROUP: u32 = 0x02000000;
    pub const NEWUTS: u32 = 0x04000000;
    pub const NEWIPC: u32 = 0x08000000;
    pub const NEWPID: u32 = 0x20000000;
    pub const NEWNET: u32 = 0x40000000;
};
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

// pub const MS = struct {
//     pub const RDONLY: u32 = 1 << 0;
//     pub const NOSUID: u32 = 1 << 1;
//     pub const NODEV: u32 = 1 << 2;
//     pub const NOEXEC: u32 = 1 << 3;
//     pub const REC: u32 = 1 << 14;
//     pub const PRIVATE: u32 = 1 << 18;
// };

pub const OPEN_TREE = struct {
    pub const CLONE: u32 = 1 << 0;
    pub const CLOEXEC: u32 = @backingInt(linux.O{ .CLOEXEC = true });
};

pub const AT = struct {
    // isize -> usize for syscall
    pub const FDCWD: usize = @bitCast(@as(isize, linux.AT.FDCWD));
    pub const EMPTY_PATH: u32 = 0x1000;
    pub const SYMLINK_NOFOLLOW: u32 = 0x100;
    pub const RECURSIVE: u32 = 0x8000;
};

pub const MountAttrFlag = packed struct(u64) {
    read_only: bool = false,
    no_suid: bool = false,
    no_dev: bool = false,
    no_exec: bool = false,
    _a: u60 = 0,
};
// pub const MOUNT_ATTR = struct {
//     pub const RDONLY: u64 = 0x01;
//     pub const NOSUID: u64 = 0x02;
//     pub const NODEV: u64 = 0x04;
//     pub const NOEXEC: u64 = 0x08;
// };

pub const MOVE_MOUNT = struct {
    pub const F_EMPTY_PATH: u32 = 0x04;
};

pub const MNT = struct {
    pub const DETACH: u32 = 0x02;
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

pub fn mount_tmpfs(target: [:0]const u8, options: [:0]const u8, allow_exec: bool) !void {
    const rc = linux.mount(
        "tmpfs",
        target.ptr,
        "tmpfs",
        @backingInt(Ms{
            .no_suid = true,
            .no_dev = true,
            .no_exec = !allow_exec,
        }),
        @intFromPtr(options.ptr),
    );
    if (linux.errno(rc) != .SUCCESS)
        return error.MountFailed;
}

pub fn mount_proc(target: [:0]const u8) !void {
    const rc = linux.mount(
        "proc",
        target.ptr,
        "proc",
        @backingInt(Ms{
            .no_suid = true,
            .no_dev = true,
            .no_exec = true,
        }),
        0,
    );
    if (linux.errno(rc) != .SUCCESS)
        return error.MountFailed;
}

pub fn bind(source: [:0]const u8, target: [:0]const u8, opts: BindOpts) !void {
    const tree_rc = linux.syscall3(
        .open_tree,
        AT.FDCWD,
        @intFromPtr(source.ptr),
        OPEN_TREE.CLONE | OPEN_TREE.CLOEXEC | AT.RECURSIVE,
    );
    if (linux.errno(tree_rc) != .SUCCESS)
        return error.OpenTreeFailed;

    const tree_fd: linux.fd_t = @intCast(tree_rc);
    defer _ = linux.close(tree_fd);

    // 2. Set VFS security flags on the detached mount FD
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
        AT.EMPTY_PATH | AT.RECURSIVE,
        @intFromPtr(&attr),
        @sizeOf(MountAttr),
    );
    if (linux.errno(setattr_rc) != .SUCCESS)
        return error.MountSetAttrFailed;

    const move_rc = linux.syscall5(
        .move_mount,
        @intCast(tree_fd),
        @intFromPtr(""),
        AT.FDCWD,
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
        AT.FDCWD,
        @intFromPtr(target_mount_path.ptr),
        AT.SYMLINK_NOFOLLOW,
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

    const umount_rc = linux.umount2(".", MNT.DETACH);
    if (linux.errno(umount_rc) != .SUCCESS)
        return error.UmountOldRootFailed;
    if (linux.errno(linux.chdir("/")) != .SUCCESS)
        return error.ChdirRootFailed;
}
