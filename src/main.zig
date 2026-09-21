const std = @import("std");

const ClientInstall = @import("client/ClientInstall.zig");
const cmd_follow = @import("client/cmd_follow.zig");
const cmd_monitor = @import("client/cmd_monitor.zig");
const cmd_remote = @import("client/cmd_remote.zig");
const Deployment = @import("client/Deployment.zig");
const cmd_do = @import("client/do.zig");
const Project = @import("client/Project.zig");
const Step = @import("client/Step.zig");
const clinternal = @import("daemon/clinternal.zig");
const Daemon = @import("daemon/Daemon.zig");
const DaemonInstall = @import("daemon/DaemonInstall.zig");
const Task = @import("daemon/Task.zig");
const Term = @import("domain/Term.zig");
pub const Monitor = @import("util/Monitor.zig");

pub const std_options: std.Options = .{
    .fmt_max_depth = 10,
};

const usage_text =
    \\Usage: weft [options] <command> [args]
    \\
    \\Commands:
    \\  daemon install [--user <name>]       Install the weft daemon (systemd service, config)
    \\  daemon run                           Run the daemon in the foreground
    \\  daemon show-token                    Print the daemon secret token
    \\  do <target...>                       Run pipelines: weft do [remote.]pipeline ...
    \\  continue [id] [targets]              Continue an existing deployment
    \\  follow [id][.pipeline]               Follow a running deployment or pipeline
    \\  monitor [group]                      Monitor system statistics for a remote group
    \\  remote install <name> <ssh> [host]   Install weft on a remote and register it
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
                var maybe_user: ?[]const u8 = null;
                var arg_i: usize = first + 2;
                while (arg_i < args.len) : (arg_i += 1) {
                    if (std.mem.eql(u8, args[arg_i], "--user") and arg_i + 1 < args.len) {
                        arg_i += 1;
                        maybe_user = args[arg_i];
                    }
                }
                try DaemonInstall.install(init.io, alloc, &term, maybe_user);
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
        } else if (std.mem.eql(u8, cmd, "remote")) {
            if (first + 1 >= args.len) break :cmd;
            const sub = args[first + 1];

            if (std.mem.eql(u8, sub, "install")) {
                if (args.len < first + 4) {
                    term.err("usage: weft remote install <name> <ssh_target> [host] [--user <username>]", .{});
                    return error.Usage;
                }
                const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
                const name = args[first + 2];
                const ssh_target = args[first + 3];

                var maybe_host: ?[]const u8 = null;
                var extra_start: usize = first + 4;
                if (first + 4 < args.len and !std.mem.startsWith(u8, args[first + 4], "-")) {
                    maybe_host = args[first + 4];
                    extra_start = first + 5;
                }
                const extra_args = if (extra_start < args.len) args[extra_start..] else &.{};

                return cmd_remote.install(alloc, init.io, &term, installation, name, ssh_target, maybe_host, extra_args);
            }
            break :cmd;
        } else if (std.mem.eql(u8, cmd, "do")) {
            if (args.len < first + 2) {
                term.err("usage: weft do [remote].pipeline [[remote].pipeline ...]", .{});
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
                const step = if (arg.len > 0 and arg[0] == '.')
                    try std.mem.join(init.arena.allocator(), "", &.{ "local", arg })
                else
                    @as([]const u8, arg);

                const target = Step.parse(step) catch |err| {
                    term.err("invalid target '{s}': {any}. A step must have the form '[remote].{{pipeline}}', ('.{{pipeline}}' implies remote is 'local')", .{ arg, err });
                    return err;
                };
                try targets.append(alloc, target);
            }
            const targets_slice = try targets.toOwnedSlice(alloc);
            defer alloc.free(targets_slice);

            return cmd_do.run(alloc, init.io, &term, project, installation, targets_slice, null);
        } else if (std.mem.eql(u8, cmd, "continue")) {
            var arg_start = first + 1;
            const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            var maybe_continue_id: ?Deployment.Id = null;
            if (arg_start < args.len) {
                if (project.find_deployment_id(init.io, args[arg_start])) |id| {
                    maybe_continue_id = id;
                    arg_start += 1;
                } else |_| {}
            }
            if (maybe_continue_id == null) {
                maybe_continue_id = try project.latest_deployment_id(init.io) orelse {
                    term.err("no deployments found in .weft", .{});
                    return error.NoDeployments;
                };
            }

            const target_args = args[arg_start..];
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

            return cmd_do.run(alloc, init.io, &term, project, installation, targets_slice, maybe_continue_id);
        } else if (std.mem.eql(u8, cmd, "follow")) {
            const follow_args = args[first + 1 ..];
            const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            return cmd_follow.run(alloc, init.io, &term, project, installation, follow_args);
        } else if (std.mem.eql(u8, cmd, "monitor")) {
            const target_group: ?[]const u8 = if (first + 1 < args.len) args[first + 1] else null;
            const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
            return cmd_monitor.run(alloc, init.io, &term, installation, target_group);
        }
    }
    show_usage(&term);
}

test {
    std.testing.refAllDecls(@This());
}
