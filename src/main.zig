pub const std_options: std.Options = .{
    .fmt_max_depth = 10,
};

fn show_usage() void {
    std.debug.print("Usage", .{});
}

pub fn main(init: std.process.Init) !void {
    const ac = init.gpa;
    const args = try init.minimal.args.toSlice(ac);
    defer ac.free(args);
    var allocator: std.heap.DebugAllocator(.{
        .stack_trace_frames = 50,
    }) = .init;
    defer _ = allocator.deinit();
    const alloc = allocator.allocator();

    var term = try Term.init(alloc, init.io);
    defer term.deinit(alloc, init.io);
    defer _ = term.flush() catch {};

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "daemon")) {
            if (args.len > 2) {
                if (std.mem.eql(u8, args[2], "install")) {
                    try DaemonInstall.install(init.io, alloc);
                    return;
                } else if (std.mem.eql(u8, args[2], "run")) {
                    const installation: DaemonInstall = try .init(init.io);
                    var daemon = try Daemon.init(alloc, init.io, installation, &term);
                    defer daemon.deinit();
                    try term.printlnf("Starting daemon on :{any}", .{daemon.config.port});
                    return daemon.run();
                }
            }
        } else if (std.mem.eql(u8, args[1], "do")) {
            if (args.len < 3) {
                try term.err("Usage: weft do [remote.]pipeline [[remote.]pipeline ...]", .{});
                return;
            }
            const target_args = args[2..];
            const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            var targets: std.ArrayList(Step) = .empty;
            defer targets.deinit(alloc);

            for (target_args) |arg| {
                const target = Step.parse(arg) catch |err| {
                    try term.err("Invalid target: {any}: {s}, ", .{ err, arg });
                    return err;
                };
                try targets.append(alloc, target);
            }
            const targets_slice = try targets.toOwnedSlice(alloc);
            defer alloc.free(targets_slice);

            return cmd_do.run(alloc, init.io, &term, project, installation, targets_slice);
        } else if (std.mem.eql(u8, args[1], "remote")) {
            if (args.len > 2) {
                if (std.mem.eql(u8, args[2], "add")) {
                    if (args.len != 4) {
                        try term.err("Invalid arguments: Remote name required", .{});
                        return;
                    }
                    const name = args[3];

                    var buf_back: [1 << 7]u8 = undefined;
                    var buf: []u8 = &buf_back;

                    try term.printlnf("remote address: ", .{});
                    const raw_addr = try term.read_line(buf);
                    const addr = std.mem.trim(u8, raw_addr, "\r\n ");
                    buf = buf[raw_addr.len..];

                    try term.printlnf("remote port(9338): ", .{});
                    const raw_port = try term.read_line(buf);
                    buf = buf[raw_port.len..];
                    const port_str = std.mem.trim(u8, raw_port, "\r\n ");
                    const port = if (port_str.len == 0)
                        9338
                    else
                        std.fmt.parseInt(u16, port_str, 10) catch |err| {
                            try term.err("Invalid port '{s}': {any}", .{ port_str, err });
                            return;
                        };

                    try term.printlnf("remote token: ", .{});
                    const raw_token = try term.read_line(buf);
                    const token_hex = std.mem.trim(u8, raw_token, "\r\n ");

                    if (token_hex.len != 64) {
                        try term.err("Invalid token length, expected 64 hex characters (32 bytes), got {d}", .{token_hex.len});
                        return;
                    }

                    const token = try std.fmt.hexToBytes(buf[0..32], token_hex);

                    const address = std.Io.net.IpAddress.parse(addr, port) catch |err| {
                        try term.err("Invalid Ip Address: {any}", .{err});
                        return err;
                    };

                    const remote: ClientInstall.Remote = .{
                        .name = name,
                        .address = address,
                        .token = token,
                    };

                    const install = try ClientInstall.init(
                        alloc,
                        init.io,
                        init.environ_map,
                    );

                    try install.add_remotes(
                        alloc,
                        init.io,
                        &.{remote},
                    );
                }
            }
        }
    }
    show_usage();
}

const cmd_do = @import("client/do.zig");

const std = @import("std");
const DaemonInstall = @import("DaemonInstall.zig");
const ClientInstall = @import("ClientInstall.zig");
const Daemon = @import("daemon/Daemon.zig");
const Term = @import("Term.zig");
const Project = @import("Project.zig");
const Step = @import("Step.zig");
