const std = @import("std");

const ClientInstall = @import("client/ClientInstall.zig");
const cmd_do = @import("client/do.zig");
const Project = @import("client/Project.zig");
const Step = @import("client/Step.zig");
const cmd_remote = @import("client/cmd_remote.zig");
const clinternal = @import("daemon/clinternal.zig");
const Daemon = @import("daemon/Daemon.zig");
const DaemonInstall = @import("daemon/DaemonInstall.zig");
const Task = @import("daemon/Task.zig");
const Term = @import("domain/Term.zig");

pub const std_options: std.Options = .{
    .fmt_max_depth = 10,
};

const usage_text =
    \\Usage: weft [options] <command> [args]
    \\
    \\Commands:
    \\  daemon install          Install the weft daemon (systemd service, config)
    \\  daemon run              Run the daemon in the foreground
    \\  daemon show-token       Print the daemon secret token
    \\  daemon install-remote   Install weft daemon on a remote host via SSH
    \\  do <pipeline[.remote]...>        Run pipelines: weft do [remote.]pipeline ...
    \\  remote add <name> <ssh> [host]   Add and install a remote via SSH
    \\
    \\Options (before the command):
    \\  -q, --quiet             Only log errors
    \\  -v, --verbose           Also log debug messages
    \\  --no-color              Disable colored output
    \\
;
fn show_usage(term: *Term) void {
    term.print(usage_text, .{});
}

fn parse_options(args: []const []const u8, term: *Term) usize {
    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (!std.mem.startsWith(u8, arg, "-"))
            break;
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet"))
            term.log_level = .err
        else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose"))
            term.log_level = .debug
        else if (std.mem.eql(u8, arg, "--no-color"))
            term.color = false
        else
            break;
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

    if (first < args.len) cmd: {
        const cmd = args[first];

        if (std.mem.eql(u8, cmd, "daemon")) {
            if (first + 1 >= args.len) break :cmd;
            const sub = args[first + 1];

            if (std.mem.eql(u8, sub, "install")) {
                try DaemonInstall.install(init.io, alloc, &term);
                term.success("weft daemon installed", .{});
                return;
            } else if (std.mem.eql(u8, sub, "run")) {
                const installation: DaemonInstall = try .init(init.io);
                var daemon = try Daemon.init(alloc, init.io, installation, &term);
                defer daemon.deinit();
                term.info("starting daemon on :{d}", .{daemon.config.port});
                return daemon.run();
            } else if (std.mem.eql(u8, sub, "show-token") or std.mem.eql(u8, sub, "token") or (std.mem.eql(u8, sub, "show") and first + 2 < args.len and std.mem.eql(u8, args[first + 2], "token"))) {
                const config = try DaemonInstall.read_config(init.io, alloc, &term);
                defer std.zon.parse.free(alloc, config);
                term.println("{s}", .{config.secret});
                return;
            } else if (std.mem.eql(u8, sub, "install-remote")) {
                if (args.len < first + 4) {
                    term.err("usage: weft daemon install-remote <name> <ssh_target> [host]", .{});
                    return error.Usage;
                }
                const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
                const name = args[first + 2];
                const ssh_target = args[first + 3];
                const maybe_host = if (args.len > first + 4) args[first + 4] else null;
                return cmd_remote.install(alloc, init.io, &term, installation, name, ssh_target, maybe_host);
            }
            break :cmd;
        } else if (std.mem.eql(u8, cmd, "remote")) {
            if (first + 1 >= args.len) break :cmd;
            const sub = args[first + 1];

            if (std.mem.eql(u8, sub, "add") or std.mem.eql(u8, sub, "install")) {
                if (args.len < first + 4) {
                    term.err("usage: weft remote add <name> <ssh_target> [host]", .{});
                    return error.Usage;
                }
                const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
                const name = args[first + 2];
                const ssh_target = args[first + 3];
                const maybe_host = if (args.len > first + 4) args[first + 4] else null;
                return cmd_remote.install(alloc, init.io, &term, installation, name, ssh_target, maybe_host);
            }
            break :cmd;
        } else if (std.mem.eql(u8, cmd, "_daemon")) {
            if (first + 1 >= args.len)
                @panic("Invalid arguments");
            const sub = args[first + 1];

            if (std.mem.eql(u8, sub, "completed")) {
                if (first + 3 >= args.len)
                    @panic("Invalid arguments");
                const task = Task.from_unit_name(args[first + 2]) orelse @panic("Invalid task unit name");
                const exit_code = try std.fmt.parseInt(u16, args[first + 3], 10);
                try clinternal.task_completed(alloc, init.io, &term, task, exit_code);
                return;
            }
        } else if (std.mem.eql(u8, cmd, "do")) {
            if (args.len < first + 2) {
                term.err("usage: weft do [remote.]pipeline [[remote.]pipeline ...]", .{});
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
                    term.err("invalid target '{s}': {any}", .{ arg, err });
                    return err;
                };
                try targets.append(alloc, target);
            }
            const targets_slice = try targets.toOwnedSlice(alloc);
            defer alloc.free(targets_slice);

            return cmd_do.run(alloc, init.io, &term, project, installation, targets_slice);
        }
    }
    show_usage(&term);
}

test {
    std.testing.refAllDecls(@This());
}
