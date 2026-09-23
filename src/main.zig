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
    @"continue": struct {
        pub const doc = "Continue an existing deployment";
        pub const doc_deployment = "The id of the deployment, or shortened id containing the last unique letters of the deployment id";
        pub const doc_targets = "Additional targets for the deployment";

        deployment: ?[]const u8 = null,
        targets: []Step = &.{},
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
    },
    help: struct {
        pub const doc = "Show this help message";
    },
    nop: struct {
        pub const doc = "Do nothing";
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
            term.color = false
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

            return cmd_do.run(alloc, init.io, &term, project, installation, cmd.targets, null);
        },
        .@"continue" => |cmd| {
            const installation: ClientInstall = try .init(alloc, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            var maybe_continue_id: ?Deployment.Id = null;
            var extra_targets: []const Step = cmd.targets;

            if (cmd.deployment) |dep_arg| {
                if (project.find_deployment_id(init.io, dep_arg)) |id| {
                    maybe_continue_id = id;
                } else |_| {
                    if (Step.argz_parse(arena_alloc, init.io, dep_arg)) |step| {
                        var targets_list: std.ArrayList(Step) = .empty;
                        defer targets_list.deinit(alloc);
                        try targets_list.append(alloc, step);
                        for (cmd.targets) |t| {
                            try targets_list.append(alloc, t);
                        }
                        extra_targets = try targets_list.toOwnedSlice(alloc);
                    } else |_| {
                        term.err("deployment '{s}' not found or invalid step", .{dep_arg});
                        return error.InvalidDeploymentId;
                    }
                }
            }
            if (maybe_continue_id == null) {
                maybe_continue_id = try project.latest_deployment_id(init.io) orelse {
                    term.err("no deployments found in .weft", .{});
                    return error.NoDeployments;
                };
            }

            return cmd_do.run(alloc, init.io, &term, project, installation, extra_targets, maybe_continue_id);
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
        },
        .help => {
            term.print("{s}", .{argz.doc("weft", Argz)});
        },
        .nop => {},
    }
}

test "main Argz parsing all commands" {
    const alloc = std.testing.allocator;

    // daemon install
    const cmd_d_inst = try argz.parse(Argz, alloc, null, &.{ "daemon", "install", "--user", "runner" });
    switch (cmd_d_inst) {
        .daemon => |d| switch (d) {
            .install => |i| try std.testing.expectEqualStrings("runner", i.user.?),
            else => unreachable,
        },
        else => unreachable,
    }

    // daemon run
    const cmd_d_run = try argz.parse(Argz, alloc, null, &.{ "daemon", "run" });
    switch (cmd_d_run) {
        .daemon => |d| switch (d) {
            .run => {},
            else => unreachable,
        },
        else => unreachable,
    }

    // daemon token
    const cmd_d_token = try argz.parse(Argz, alloc, null, &.{ "daemon", "token" });
    switch (cmd_d_token) {
        .daemon => |d| switch (d) {
            .token => {},
            else => unreachable,
        },
        else => unreachable,
    }

    // daemon ipc completed
    const dep_id = try Deployment.Id.now(std.testing.io);
    var buf: [128]u8 = undefined;
    const task_unit = try std.fmt.bufPrint(&buf, "weft-runner--myws--mypip--{s}", .{&dep_id.to_string()});
    const cmd_d_ipc = try argz.parse(Argz, alloc, null, &.{ "daemon", "ipc", "completed", task_unit, "0" });
    switch (cmd_d_ipc) {
        .daemon => |d| switch (d) {
            .ipc => |i| switch (i) {
                .completed => |c| {
                    try std.testing.expectEqualStrings("myws", c.task.id.workspace);
                    try std.testing.expectEqualStrings("mypip", c.task.id.pipeline);
                    try std.testing.expectEqual(@as(u16, 0), c.code);
                },
            },
            else => unreachable,
        },
        else => unreachable,
    }

    // do targets
    const cmd_do_val = try argz.parse(Argz, alloc, null, &.{ "do", ".build", "remote1.deploy" });
    switch (cmd_do_val) {
        .do => |d| {
            try std.testing.expectEqual(@as(usize, 2), d.targets.len);
            try std.testing.expectEqualStrings("local", d.targets[0].remote);
            try std.testing.expectEqualStrings("build", d.targets[0].pipeline);
            try std.testing.expectEqualStrings("remote1", d.targets[1].remote);
            try std.testing.expectEqualStrings("deploy", d.targets[1].pipeline);
            alloc.free(d.targets);
        },
        else => unreachable,
    }

    // continue
    const cmd_cont = try argz.parse(Argz, alloc, null, &.{ "continue", "abc12345", ".test" });
    switch (cmd_cont) {
        .@"continue" => |c| {
            try std.testing.expectEqualStrings("abc12345", c.deployment.?);
            try std.testing.expectEqual(@as(usize, 1), c.targets.len);
            try std.testing.expectEqualStrings("local", c.targets[0].remote);
            try std.testing.expectEqualStrings("test", c.targets[0].pipeline);
            alloc.free(c.targets);
        },
        else => unreachable,
    }

    // follow
    const cmd_follow_val = try argz.parse(Argz, alloc, null, &.{ "follow", "abc.build" });
    switch (cmd_follow_val) {
        .follow => |f| try std.testing.expectEqualStrings("abc.build", f.spec.?),
        else => unreachable,
    }

    // monitor
    const cmd_mon_val = try argz.parse(Argz, alloc, null, &.{ "monitor", "production" });
    switch (cmd_mon_val) {
        .monitor => |m| try std.testing.expectEqualStrings("production", m.spec.?),
        else => unreachable,
    }

    // remote install
    const cmd_rem_val = try argz.parse(Argz, alloc, null, &.{ "remote", "install", "srv1", "root@10.0.0.1", "10.0.0.1:9338", "--user", "weftuser", "extra1" });
    switch (cmd_rem_val) {
        .remote => |r| switch (r) {
            .install => |inst| {
                try std.testing.expectEqualStrings("srv1", inst.name);
                try std.testing.expectEqualStrings("root@10.0.0.1", inst.ssh);
                try std.testing.expectEqualStrings("10.0.0.1", inst.addr.?.host);
                try std.testing.expectEqual(@as(?u16, 9338), inst.addr.?.port);
                try std.testing.expectEqualStrings("weftuser", inst.user.?);
                try std.testing.expectEqual(@as(usize, 1), inst.extra.len);
                try std.testing.expectEqualStrings("extra1", inst.extra[0]);
                alloc.free(inst.extra);
            },
        },
        else => unreachable,
    }

    // help
    const cmd_help_val = try argz.parse(Argz, alloc, null, &.{"help"});
    switch (cmd_help_val) {
        .help => {},
        else => unreachable,
    }

    // nop
    const cmd_nop_val = try argz.parse(Argz, alloc, null, &.{"nop"});
    switch (cmd_nop_val) {
        .nop => {},
        else => unreachable,
    }
}

test "parse_term_options" {
    var term = try Term.init(std.testing.allocator, std.testing.io);
    defer term.deinit(std.testing.allocator, std.testing.io);

    const args = [_][]const u8{ "weft", "-q", "--no-color", "do", ".build" };
    const first = parse_term_options(&args, &term);
    try std.testing.expectEqual(@as(usize, 3), first);
    try std.testing.expectEqual(Term.Level.err, term.log_level);
    try std.testing.expectEqual(false, term.color);
}

test {
    std.testing.refAllDecls(@This());
}
