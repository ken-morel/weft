const std = @import("std");

const Deployment = @import("../client/Deployment.zig");
const Weft = @import("../domain/Weft.zig");

pub fn Res(comptime T: type) type {
    return anyerror!T;
}

pub const artifact = struct {
    pub const push = struct {
        pub const Req = union(enum) {
            header: struct { id: task.Id },
            folder: []const u8,
            file: []const u8,
            data: []const u8,
            raw: []const u8,
            end,
        };
        pub const Res = union(enum) {
            has_artifact: bool,
            footer: struct {},
        };
    };
    pub const has = struct {
        pub const Req = struct {
            id: task.Id,
        };
        pub const Res = struct {
            has: bool,
        };
    };
    pub const pull = struct {
        pub const Req = union(enum) {
            header: struct {
                id: task.Id,
            },
        };
        pub const Res = union(enum) {
            files: u32,
            folder: []const u8,
            file: []const u8,
            raw: []const u8,
            compressed: []const u8,
            end,
            footer: struct {},
        };
    };
    pub const Id = task.Id;
};
pub const task = struct {
    pub const Id = struct {
        workspace: []const u8,
        service: []const u8,
        deployment: Deployment.Id,
        pipeline: []const u8,
        pub fn dupe(self: @This(), alloc: std.mem.Allocator) !@This() {
            const workspace = try alloc.dupe(u8, self.workspace);
            errdefer alloc.free(workspace);
            const service = try alloc.dupe(u8, self.service);
            errdefer alloc.free(service);
            const pipeline = try alloc.dupe(u8, self.pipeline);
            errdefer alloc.free(pipeline);
            return .{
                .workspace = workspace,
                .service = service,
                .deployment = self.deployment,
                .pipeline = pipeline,
            };
        }
        pub fn free_duped(self: @This(), alloc: std.mem.Allocator) void {
            alloc.free(self.workspace);
            alloc.free(self.service);
            alloc.free(self.pipeline);
        }
    };

    pub const spawn = struct {
        pub const data: u8 = 0xba;
        pub const end: u8 = 0xbb;
        pub const Req = struct {
            task: task.Id,
            pipeline: Weft.Pipeline,
        };
        pub const Res = struct {};
    };
    pub const poll = struct {
        pub const Req = union(enum) {
            header: struct {
                task: Id,
                logs_offset: ?u64,
            },
        };
        pub const Logs = struct {
            data: []const u8,
            compressed: bool,
            end_offset: u64,
        };
        pub const Status = union(enum) {
            running,
            success,
            failed: u16,
            not_found,
        };
        pub const Res = union(enum) {
            footer: struct {
                logs: ?Logs,
                status: Status,
            },
        };
    };
};
pub const system = struct {
    pub const stats = struct {
        pub const CpuCore = struct {
            core_id: u16,
            freq_mhz: u32,
            usage_percent: u8,
        };

        pub const Cpu = struct {
            model: []const u8,
            cores_count: u16,
            total_usage_percent: u8,
            avg_freq_mhz: u32,
            cores: []const CpuCore,
        };

        pub const Ram = struct {
            total: u64,
            used: u64,
            free: u64,
            available: u64,
            buffers: u64,
            cached: u64,
        };

        pub const Swap = struct {
            total: u64,
            used: u64,
            free: u64,
            in_bytes: u64,
            out_bytes: u64,
        };

        pub const ZramDevice = struct {
            name: []const u8,
            disksize: u64,
            orig_data_size: u64,
            compr_data_size: u64,
            mem_used_total: u64,
        };

        pub const Zram = struct {
            total: u64,
            used: u64,
            compressed: u64,
            devices: []const ZramDevice,
        };

        pub const DiskMount = struct {
            mount_point: []const u8,
            device: []const u8,
            fs_type: []const u8,
            total_bytes: u64,
            used_bytes: u64,
            avail_bytes: u64,
        };

        pub const DiskIo = struct {
            device: []const u8,
            read_bytes: u64,
            written_bytes: u64,
            read_ops: u64,
            write_ops: u64,
            io_time_ms: u64,
        };

        pub const NetDev = struct {
            interface: []const u8,
            rx_bytes: u64,
            tx_bytes: u64,
            rx_packets: u64,
            tx_packets: u64,
            rx_errors: u64,
            tx_errors: u64,
        };

        pub const Service = struct {
            workspace: []const u8,
            service: []const u8,
            pipeline: []const u8,
            deployment: Deployment.Id,
            unit_name: []const u8,
            cpu_usage_usec: u64,
            memory_bytes: u64,
            memory_peak_bytes: u64,
            io_read_bytes: u64,
            io_write_bytes: u64,
        };

        pub const Stats = struct {
            time: std.Io.Timestamp,
            cpu: Cpu,
            ram: Ram,
            swap: Swap,
            zram: Zram,
            disks: []const DiskMount,
            disk_io: []const DiskIo,
            net: []const NetDev,
            services: []const Service,
        };

        pub const Req = struct {
            from: std.Io.Timestamp,
        };
        pub const Res = struct {
            stats: []const Stats,
        };
    };
};

pub const Request = enum(u8) {
    artifact_push,
    artifact_pull,
    artifact_has,

    task_spawn,
    task_poll,

    system_stats,
};

pub const DaemonMsg = union(enum) {
    const TaskCompleted = struct {
        status: u16,
        task: task.Id,
    };
    task_completed: TaskCompleted,
};
