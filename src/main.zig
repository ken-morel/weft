const std = @import("std");

const ClientInstall = @import("client/ClientInstall.zig");
const cmd_follow = @import("client/cmd_follow.zig");
const cmd_list = @import("client/cmd_list.zig");
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
const argz = @import("util/argz.zig");
pub const Monitor = @import("util/Monitor.zig");

pub const std_options: std.Options = .{
    .fmt_max_depth = 10,
};

const Argz = union(enum) {
    pub const doc =
        \\Weft, a deployment tool
        \\Options (before the command):
        \\  -q, --quiet             Only log errors
        \\  -v, --verbose           Also log debug messages
        \\  --no-color              Disable colored output
        \\
    ;
    daemon: union(enum) {
        pub const doc = "Perform actions on the local daemon";
        install: struct {
            pub const doc = "Install the weft daemon locally, requires superuser priviledges";
            pub const doc_user = "Use an existing user to run tasks, instead of 'weft-runner'.";
            user: ?[]const u8 = null,
        },
        run: struct {
            pub const doc = "Run the weft daemon, requires superuser priviledges";
        },
        token: struct {
            pub const doc = "Display the daemon's access token";
        },
        ipc: union(enum) {
            pub const hidden = true;
            completed: struct {
                task: Task,
                code: u16,
            },
        },
    },

    do: struct {
        pub const doc = "Start a deployment";
        pub const doc_targets = "The different deployment targets";

        targets: []Step = &.{},
    },
    retry: struct {
        pub const doc = "Retry an existing deployment";
        pub const doc_deployment = "The id of the deployment, or shortened id containing the last unique letters of the deployment id (defaults to latest)";

        deployment: ?[]const u8 = null,
    },
    list: struct {
        pub const doc = "List recent deployments and their status";
    },
    follow: struct {
        pub const doc = "Follow a running deployment or pipelines";
        pub const doc_spec = "The specifier with the format [id][.pipeline] if nothing is specified then the last deployment is followed";

        spec: ?[]const u8 = null,
    },
    monitor: struct {
        pub const doc = "Monitor a remote or remote group";
        pub const doc_spec = "The remote or remote group to follow. If ommited all remotes will be followed";

        spec: ?[]const u8 = null,
    },
    remote: union(enum) {
        pub const doc = "Perform actions on a remote";

        install: struct {
            pub const doc = "Install weft on a remote via ssh and register it";
            pub const doc_name = "The name to assign to the remote when registering. If the name is taken the remote will be updated";
            pub const doc_ssh = "The ssh id of the remote, or ip:port tuple";
            pub const doc_addr = "The external address to register";
            pub const doc_user = "Use an existing user to run tasks on the remote, instead of 'weft-runner'";
            pub const doc_extra = "Extra arguments to pass to the install command";

            name: []const u8,
            ssh: []const u8,
            addr: ?argz.SocketAddr = null,
            user: ?[]const u8 = null,
            extra: [][]const u8 = &.{},
        },
        list: struct {
            pub const doc = "List registered remotes";
        },
        remove: struct {
            pub const doc = "Remove a remote from remotes.zon";
            pub const doc_name = "The name of the remote to remove";

            name: []const u8,
        },
    },
    help: struct {
        pub const doc = "Show help";
        pub const doc_command = "Document a specific command";
        command: [][]const u8,
    },
    nop: struct {
        pub const hidden = true;
    },
};

fn parse_term_options(args: []const []const u8, term: *Term) usize {
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
            term.is_tty = false
        else
            break;
    }
    return idx;
}

pub fn main(init: std.process.Init) !void {
    var allocator: std.heap.DebugAllocator(.{
        .stack_trace_frames = 10,
    }) = .init;
    defer _ = allocator.deinit();
    const alloc = allocator.allocator();

    const arena_alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena_alloc);

    var term = try Term.init(alloc, init.io);
    defer {
        _ = term.flush() catch {};
        term.deinit(alloc, init.io);
    }

    const first = parse_term_options(args, &term);

    if (args.len <= first or (args.len > first and (std.mem.eql(u8, args[first], "--help") or std.mem.eql(u8, args[first], "-h")))) {
        term.print("{s}", .{argz.doc("weft", Argz)});
        return;
    }

    const parsed_cmd = argz.parse(Argz, arena_alloc, init.io, args[first..]) catch |err| {
        if (err == error.ExpectedCommand or err == error.InvalidCommand) {
            term.print("{s}", .{argz.doc("weft", Argz)});
            return;
        }
        term.err("failed to parse arguments: {any}", .{err});
        return err;
    };

    switch (parsed_cmd) {
        .daemon => |d| switch (d) {
            .install => |i| {
                try DaemonInstall.install(init.io, alloc, &term, i.user);
                term.success("weft daemon installed", .{});
            },
            .run => {
                const installation: DaemonInstall = try .init(init.io);
                var daemon = try Daemon.init(alloc, init.io, installation, &term);
                defer daemon.deinit();
                term.info("starting daemon on :{d}", .{daemon.config.port});
                return daemon.run();
            },
            .token => {
                const config = try DaemonInstall.read_config(init.io, alloc, &term);
                defer std.zon.parse.free(alloc, config);
                term.println("{s}", .{config.secret});
            },
            .ipc => |i| switch (i) {
                .completed => |msg| {
                    try clinternal.task_completed(alloc, init.io, &term, msg.task, msg.code);
                },
            },
        },
        .do => |cmd| {
            if (cmd.targets.len == 0) {
                term.err("usage: weft do [remote].pipeline [[remote].pipeline ...]", .{});
                return error.Usage;
            }
            const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            return cmd_do.run(alloc, init.io, &term, project, installation, .{ .start = cmd.targets });
        },
        .retry => |cmd| {
            const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            const resume_id = if (cmd.deployment) |dep_arg|
                project.find_deployment_id(init.io, dep_arg) catch {
                    term.err("deployment '{s}' not found or ambiguous", .{dep_arg});
                    return error.InvalidDeploymentId;
                }
            else
                try project.latest_deployment_id(init.io) orelse {
                    term.err("no deployments found in .weft", .{});
                    return error.NoDeployments;
                };

            return cmd_do.run(alloc, init.io, &term, project, installation, .{ .retry = resume_id });
        },
        .list => {
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            return cmd_list.run(alloc, init.io, &term, project);
        },
        .follow => |cmd| {
            const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            const follow_args: []const []const u8 = if (cmd.spec) |s| &.{s} else &.{};
            return cmd_follow.run(alloc, init.io, &term, project, installation, follow_args);
        },
        .monitor => |cmd| {
            const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
            return cmd_monitor.run(alloc, init.io, &term, installation, cmd.spec);
        },
        .remote => |r| switch (r) {
            .install => |install| {
                const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);

                var extra_list: std.ArrayList([]const u8) = .empty;
                defer extra_list.deinit(alloc);
                if (install.user) |user| {
                    try extra_list.append(alloc, "--user");
                    try extra_list.append(alloc, user);
                }
                for (install.extra) |arg| {
                    try extra_list.append(alloc, arg);
                }

                const weft_host: ?[]const u8 = if (install.addr) |a| a.host else null;
                const weft_port: ?u16 = if (install.addr) |a| a.port else null;

                return cmd_remote.install(
                    alloc,
                    init.io,
                    &term,
                    installation,
                    install.name,
                    install.ssh,
                    weft_host,
                    weft_port,
                    extra_list.items,
                );
            },
            .list => {
                const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
                return cmd_remote.list(alloc, init.io, &term, installation);
            },
            .remove => |r_rm| {
                const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
                return cmd_remote.remove(alloc, init.io, &term, installation, r_rm.name);
            },
        },
        .help => |cmd| {
            const command = cmd.command;
            _ = command;
            unreachable; // TODO: Define a method in argz to handle help, possibly a pluggable struct and handler function
        },
        .nop => {},
    }
}

test {
    std.testing.refAllDecls(@This());
}
