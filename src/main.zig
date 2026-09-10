pub const std_options: std.Options = .{
    .fmt_max_depth = 10,
};

const std = @import("std");
const DaemonInstall = @import("DaemonInstall.zig");
const ClientInstall = @import("ClientInstall.zig");
const Daemon = @import("daemon/Daemon.zig");
const Term = @import("Term.zig");
const Project = @import("Project.zig");
const Step = @import("Step.zig");

const usage_text =
    \\Usage: weft [options] <command> [args]
    \\
    \\Commands:
    \\  daemon install          Install the weft daemon (systemd service, config)
    \\  daemon run              Run the daemon in the foreground
    \\  do <pipeline...>        Run pipelines: weft do [remote.]pipeline ...
    \\  remote add <name>       Interactively add a remote
    \\
    \\Options (before the command):
    \\  -q, --quiet             Only log errors
    \\  -v, --verbose           Also log debug messages
    \\  --no-color              Disable colored output
    \\
;

fn show_usage(term: *Term) void {
    term.print(usage_text, .{}) catch {};
}

/// Consume leading global options, updating `term`. Returns the index of
/// the first non-option argument.
fn parse_options(args: []const []const u8, term: *Term) usize {
    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (!std.mem.startsWith(u8, arg, "-")) break;
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            term.log_level = .err;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            term.log_level = .debug;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            term.color = false;
        } else {
            break;
        }
    }
    return idx;
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

    const first = parse_options(args, &term);

    if (first < args.len) blk: {
        const cmd = args[first];

        if (std.mem.eql(u8, cmd, "daemon")) {
            if (first + 1 >= args.len) break :blk;
            const sub = args[first + 1];

            if (std.mem.eql(u8, sub, "install")) {
                try DaemonInstall.install(init.io, alloc, &term);
                try term.success("weft daemon installed", .{});
                return;
            } else if (std.mem.eql(u8, sub, "run")) {
                const installation: DaemonInstall = try .init(init.io);
                var daemon = try Daemon.init(alloc, init.io, installation, &term);
                defer daemon.deinit();
                try term.info("starting daemon on :{d}", .{daemon.config.port});
                return daemon.run();
            }
            break :blk;
        } else if (std.mem.eql(u8, cmd, "do")) {
            if (args.len < first + 2) {
                try term.err("usage: weft do [remote.]pipeline [[remote.]pipeline ...]", .{});
                return error.Usage;
            }
            const target_args = args[first + 1 ..];
            const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            var targets: std.ArrayList(Step) = .empty;
            defer targets.deinit(alloc);

            for (target_args) |arg| {
                const target = Step.parse(arg) catch |err| {
                    try term.err("invalid target '{s}': {any}", .{ arg, err });
                    return err;
                };
                try targets.append(alloc, target);
            }
            const targets_slice = try targets.toOwnedSlice(alloc);
            defer alloc.free(targets_slice);

            return cmd_do.run(alloc, init.io, &term, project, installation, targets_slice);
        } else if (std.mem.eql(u8, cmd, "remote")) {
            if (first + 1 < args.len and std.mem.eql(u8, args[first + 1], "add")) {
                if (args.len != first + 3) {
                    try term.err("invalid arguments: remote name required", .{});
                    return error.Usage;
                }
                const name = args[first + 2];

                var buf_back: [1 << 7]u8 = undefined;
                var buf: []u8 = &buf_back;

                try term.println("remote address: ", .{});
                const raw_addr = try term.read_line(buf);
                const addr = std.mem.trim(u8, raw_addr, "\r\n ");
                buf = buf[raw_addr.len..];

                try term.println("remote port (9338): ", .{});
                const raw_port = try term.read_line(buf);
                buf = buf[raw_port.len..];
                const port_str = std.mem.trim(u8, raw_port, "\r\n ");
                const port = if (port_str.len == 0)
                    9338
                else
                    std.fmt.parseInt(u16, port_str, 10) catch |err| {
                        try term.err("invalid port '{s}': {any}", .{ port_str, err });
                        return error.Usage;
                    };

                try term.println("remote token: ", .{});
                const raw_token = try term.read_line(buf);
                const token_hex = std.mem.trim(u8, raw_token, "\r\n ");

                if (token_hex.len != 64) {
                    try term.err("invalid token length, expected 64 hex characters (32 bytes), got {d}", .{token_hex.len});
                    return error.Usage;
                }

                const token = try std.fmt.hexToBytes(buf[0..32], token_hex);

                const address = std.Io.net.IpAddress.parse(addr, port) catch |err| {
                    try term.err("invalid ip address: {any}", .{err});
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
                try term.success("remote '{s}' added", .{name});
                return;
            }
            break :blk;
        }
    }
    show_usage(&term);
}

const cmd_do = @import("client/do.zig");
