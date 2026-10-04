const std = @import("std");
const builtin = @import("builtin");

const build = @import("build");

const ClientInstall = @import("client/ClientInstall.zig");
const cmd_check = @import("client/cmd_check.zig");
const cmd_follow = @import("client/cmd_follow.zig");
const cmd_gc = @import("client/cmd_gc.zig");
const cmd_kill = @import("client/cmd_kill.zig");
const cmd_monitor = @import("client/cmd_monitor.zig");
const cmd_remote = @import("client/cmd_remote.zig");
const Deployment = @import("client/Deployment.zig");
const cmd_do = @import("client/do.zig");
const Project = @import("client/Project.zig");
const Step = @import("client/Step.zig");
const clinternal = @import("daemon/clinternal.zig");
const Daemon = @import("daemon/Daemon.zig");
const DaemonInstall = @import("daemon/DaemonInstall.zig");
const nix = @import("daemon/nix.zig");
const Task = @import("daemon/Task.zig");
const proto = @import("domain/proto.zig");
const Term = @import("domain/Term.zig");
const argz = @import("util/argz.zig");
const Monitor = @import("util/Monitor.zig");

pub const std_options: std.Options = .{
    .fmt_max_depth = 10,
};

const Argz = union(enum) {
    pub const doc =
        \\Weft, a deployment tool
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
    version: struct {
        pub const doc = "Display information about the weft build";
    },

    check: struct {
        pub const doc = "Validate weft.zon";
    },

    do: struct {
        pub const doc = "Start a deployment";
        pub const doc_targets = "The different deployment targets";

        targets: [][]const u8 = &.{},
    },
    @"resume": struct {
        pub const doc = "Resume an existing possibly failed deployment";
        pub const doc_deployment = "The id of the deployment, or shortened id containing the last unique letters of the deployment id (defaults to latest)";

        deployment: ?[]const u8 = null,
    },
    follow: struct {
        pub const doc = "Follow a running/completed tasks and output logs";
        pub const doc_pipeline = "The pipeline name to follow";
        pub const doc_deployment = "The deployment id to follow (defaults to latest)";

        pipeline: []const u8,
        deployment: ?[]const u8 = null,
    },
    monitor: struct {
        pub const doc = "Monitor a remote";
        pub const doc_spec = "The remote to monitor. Follows 'local' by default ";

        spec: []const u8 = "local",
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
    kill: struct {
        pub const doc = "Kill a deployment or a specific pipeline in a deployment";
        pub const doc_remote = "The remote where to kill the task";
        pub const doc_deployment = "The deployment id";
        pub const doc_pipeline = "The pipeline name to kill";

        remote: []const u8,
        deployment: []const u8,
        pipeline: []const u8,
    },
    gc: struct {
        pub const doc = "Garbage collect old artifacts on remotes or locally";
        pub const doc_remote = "The remote to run gc on (defaults to local)";
        pub const doc_keep = "Number of recent deployments to keep (default: 5)";
        pub const doc_older_than = "Remove artifacts older than duration (e.g. 7d, 24h)";
        pub const doc_dry_run = "Show what would be removed without deleting";

        remote: []const u8 = "local",
        keep: ?u32 = null,
        older_than: ?[]const u8 = null,
        dry_run: bool = false,
    },
    nix: union(enum) {
        pub const doc = "Perform nix operations";
        show: struct {
            pub const doc = "Query hydra for the latest store path of a package";
            pub const doc_pkg = "The nix package attribute (e.g. bun, lowdown, python312)";

            pkg: []const u8,
        },
    },
    help: argz.Help,
    nop: struct {
        pub const doc = "nop";
    },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);

    var term = try Term.init(gpa, init.io);
    defer {
        _ = term.flush() catch {};
        term.deinit(gpa, init.io);
    }

    if (args.len <= 1 or
        (args.len > 1 and
            (std.mem.eql(u8, args[1], "--help") or
                std.mem.eql(u8, args[1], "-h"))))
    {
        argz.help("weft", Argz, .{ .command = &.{} }, &term);
        return;
    }

    const parsed = argz.parse(Argz, alloc, init.io, args[1..]) catch |err| {
        if (err == error.ExpectedCommand or err == error.InvalidCommand) {
            argz.help("weft", Argz, .{ .command = &.{} }, &term);
            return;
        }
        term.err("failed to parse arguments: {any}", .{err});
        return err;
    };

    switch (parsed) {
        .version => {
            const es = std.time.epoch.EpochSeconds{ .secs = @intCast(build.build_time_seconds) };
            const day = es.getDaySeconds();
            const yd = es.getEpochDay().calculateYearDay();
            const md = yd.calculateMonthDay();
            const build_time = try gpa.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{
                yd.year,
                @backingInt(md.month),
                md.day_index + 1,
                day.getHoursIntoDay(),
                day.getMinutesIntoHour(),
                day.getSecondsIntoMinute(),
            });
            defer gpa.free(build_time);

            term.println(
                \\ Weft
                \\  version:     v0.1.0-dev1 
                \\  build time:  {s}
                \\  build mode:  {s}
                \\  schema hash: {s}
            , .{
                build_time,
                @tagName(builtin.mode),
                &std.fmt.hex(proto.hash),
            });
        },
        .daemon => |d| switch (d) {
            .install => |i| {
                try DaemonInstall.install(init.io, gpa, &term, i.user);
            },
            .run => {
                const installation: DaemonInstall = try .init(init.io);
                var daemon = try Daemon.init(gpa, init.io, installation, &term);
                defer daemon.deinit();
                return daemon.run();
            },
            .token => {
                const config = try DaemonInstall.read_config_leaky(init.io, alloc, &term);
                term.println("{s}", .{config.secret});
            },
            .ipc => |i| switch (i) {
                .completed => |msg| {
                    try clinternal.task_completed(gpa, init.io, &term, msg.task, msg.code);
                },
            },
        },
        .check => {
            const installation: ClientInstall = try .init(gpa, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true });
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            try cmd_check.run(gpa, init.io, &term, project, installation);
        },
        .do => |cmd| {
            if (cmd.targets.len == 0) {
                term.err("No targets specified", .{});
                return error.Usage;
            }
            const targets: []Step = try gpa.alloc(Step, cmd.targets.len);
            defer gpa.free(targets);
            var last_mode: []const u8 = "default";
            for (cmd.targets, targets) |name, *tgt| {
                const mode_sep = std.mem.findScalar(u8, name, ':');
                if (mode_sep) |sep|
                    last_mode = name[0..sep];
                const slice = if (mode_sep) |sep|
                    name[sep + 1 ..]
                else
                    name;

                const remote_sep = std.mem.findScalar(u8, slice, '.');
                const remote = if (remote_sep) |sep|
                    slice[0..sep]
                else
                    "local";
                const pipeline = if (remote_sep) |sep|
                    slice[sep + 1 ..]
                else
                    slice;
                if (!Step.is_valid_name(last_mode) or !Step.is_valid_name(remote) or !Step.is_valid_name(pipeline))
                    return error.InvalidStep;

                tgt.* = .{
                    .mode = last_mode,
                    .remote = remote,
                    .pipeline = pipeline,
                };
            }

            const installation: ClientInstall = try .init(gpa, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            return cmd_do.run(gpa, init.io, &term, project, installation, .{
                .start = .{
                    .targets = targets,
                },
            });
        },
        .@"resume" => |cmd| {
            const installation: ClientInstall = try .init(gpa, init.io, init.environ_map);
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

            return cmd_do.run(gpa, init.io, &term, project, installation, .{ .retry = resume_id });
        },
        .follow => |cmd| {
            const installation: ClientInstall = try .init(gpa, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            return cmd_follow.run(gpa, init.io, &term, project, installation, cmd.pipeline, cmd.deployment);
        },
        .monitor => |cmd| {
            const installation: ClientInstall = try .init(gpa, init.io, init.environ_map);
            return cmd_monitor.run(gpa, init.io, &term, installation, cmd.spec);
        },
        .remote => |r| switch (r) {
            .install => |install| {
                const installation: ClientInstall = try .init(gpa, init.io, init.environ_map);

                var extra_list: std.ArrayList([]const u8) = .empty;
                defer extra_list.deinit(gpa);
                if (install.user) |user| {
                    try extra_list.append(gpa, "--user");
                    try extra_list.append(gpa, user);
                }
                for (install.extra) |arg| {
                    try extra_list.append(gpa, arg);
                }

                const weft_host: ?[]const u8 = if (install.addr) |a| a.host else null;
                const weft_port: ?u16 = if (install.addr) |a| a.port else null;

                return cmd_remote.install(
                    gpa,
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
        .kill => |cmd| {
            const installation: ClientInstall = try .init(gpa, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(project_dir);

            return try cmd_kill.run(gpa, init.io, &term, project, installation, cmd.pipeline, cmd.remote, cmd.deployment);
        },
        .gc => |cmd| {
            const installation: ClientInstall = try .init(gpa, init.io, init.environ_map);
            const project_dir = std.Io.Dir.cwd().openDir(init.io, ".", .{}) catch null;
            defer if (project_dir) |*d| d.close(init.io);
            const project = if (project_dir) |d| Project.open(d) catch null else null;

            return try cmd_gc.run(gpa, init.io, &term, project, installation, cmd.remote, cmd.keep, cmd.older_than, cmd.dry_run);
        },
        .nix => |n| switch (n) {
            .show => |cmd| {
                var client: std.http.Client = .{
                    .io = init.io,
                    .allocator = gpa,
                };
                defer client.deinit();

                const basename = nix.query_store_basename(std.heap.page_allocator, &client, cmd.pkg) catch |err| {
                    switch (err) {
                        error.PackageNotFound => {
                            term.err("package '{s}' not found on Hydra", .{cmd.pkg});
                        },
                        else => {
                            term.err("failed to query package '{s}': {s}", .{ cmd.pkg, @errorName(err) });
                        },
                    }
                    _ = term.flush() catch {};
                    std.process.exit(1);
                };
                defer gpa.free(basename);

                term.println("{s}", .{basename});
            },
        },
        .help => |cmd| {
            argz.help("weft", Argz, cmd, &term);
        },
        .nop => {},
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("util/zoto.zig");
}
