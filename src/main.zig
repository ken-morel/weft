const std = @import("std");
const log = std.log;
const scoped = log.scoped;
const builtin = @import("builtin");

const build = @import("build");

const ClientInstall = @import("client/ClientInstall.zig");
const cmd_check = @import("client/cmd_check.zig");
const cmd_kill = @import("client/cmd_kill.zig");
const cmd_logs = @import("client/cmd_logs.zig");
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
                code: ?[]const u8 = null,
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
    logs: struct {
        pub const doc = "Get the logs for a running/completed pipeline";
        pub const doc_pipeline = "The pipeline name to follow";
        pub const doc_deployment = "The deployment id to follow (defaults to latest)";
        pub const doc_remote = "The remote to query, defaults to load from deployment configuration";

        pipeline: []const u8,
        deployment: ?[]const u8 = null,
        remote: ?[]const u8 = null,
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
    nix: union(enum) {
        pub const doc = "Perform nix operations";
        show: struct {
            pub const doc = "Query hydra for the latest store path of a package";
            pub const doc_pkg = "The nix package attribute (e.g. bun, lowdown, python312)";

            pkg: []const u8,
        },
    },
    argz_help: argz.Help("weft", @This()),
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

    const parsed = argz.parse(Argz, alloc, init.io, args[1..]) catch |err| {
        log.err("failed to parse arguments: {any}; run `weft help` for help", .{err});
        return err;
    };

    switch (parsed) {
        .version => {
            const build_time = comptime build_time: {
                const es = std.time.epoch.EpochSeconds{ .secs = @intCast(build.build_time_seconds) };
                const day = es.getDaySeconds();
                const yd = es.getEpochDay().calculateYearDay();
                const md = yd.calculateMonthDay();
                break :build_time std.fmt.comptimePrint("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
                    yd.year,
                    @backingInt(md.month),
                    md.day_index + 1,
                    day.getHoursIntoDay(),
                    day.getMinutesIntoHour(),
                    day.getSecondsIntoMinute(),
                });
            };

            const version_str = std.fmt.comptimePrint(
                \\ Weft
                \\  version:     v0.1.0-dev1 
                \\  build time:  {s}
                \\  build mode:  {s}
                \\  schema hash: {s}
            , .{ // so that we can inspect this directly from binary
                comptime build_time,
                comptime @tagName(builtin.mode),
                comptime &std.fmt.hex(proto.hash),
            });

            term.println("{s}", .{version_str});
        },
        .daemon => |d| switch (d) {
            .install => |i| {
                try DaemonInstall.install(init.io, gpa, i.user);
            },
            .run => {
                const installation: DaemonInstall = try .init(init.io);
                var daemon = try Daemon.init(gpa, init.io, installation);
                defer daemon.deinit();
                return daemon.run();
            },
            .token => {
                const config = try DaemonInstall.read_config_leaky(init.io, alloc);
                term.println("{s}", .{config.secret});
            },
            .ipc => |i| switch (i) {
                .completed => |msg| {
                    const code = if (msg.code) |c|
                        std.fmt.parseInt(i32, c, 10) catch -3
                    else
                        -3;
                    try clinternal.task_completed(gpa, init.io, msg.task, code);
                },
            },
        },
        .check => {
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true });
            defer project_dir.close(init.io);
            const project = try Project.open(alloc, init.io, project_dir);

            try cmd_check.run(gpa, init.io, project);
        },
        .do => |cmd| {
            if (cmd.targets.len == 0) {
                log.err("No targets specified", .{});
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
            const project = try Project.open(alloc, init.io, project_dir);

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
            const project = try Project.open(alloc, init.io, project_dir);

            const resume_id = if (cmd.deployment) |dep_arg|
                project.find_deployment_id(init.io, dep_arg) catch {
                    log.err("deployment '{s}' not found or ambiguous", .{dep_arg});
                    return error.InvalidDeploymentId;
                }
            else
                try project.latest_deployment_id(init.io) orelse {
                    log.err("no deployments found in .weft", .{});
                    return error.NoDeployments;
                };

            return cmd_do.run(gpa, init.io, &term, project, installation, .{ .retry = resume_id });
        },
        .logs => |cmd| {
            const installation: ClientInstall = try .init(gpa, init.io, init.environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
            defer project_dir.close(init.io);
            const project = try Project.open(alloc, init.io, project_dir);

            return cmd_logs.run(
                gpa,
                init.io,
                project,
                installation,
                cmd.pipeline,
                cmd.deployment,
                cmd.remote,
            );
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
            const project = try Project.open(alloc, init.io, project_dir);

            return try cmd_kill.run(gpa, init.io, project, installation, cmd.pipeline, cmd.remote, cmd.deployment);
        },

        .nix => |n| switch (n) {
            .show => |cmd| {
                var client: std.http.Client = .{
                    .io = init.io,
                    .allocator = gpa,
                };
                defer client.deinit();

                const basename = nix.query_store_basename(gpa, &client, cmd.pkg) catch |err| {
                    if (err == error.PackageNotFound)
                        log.err("package '{s}' not found on Hydra", .{cmd.pkg});
                    return err;
                };
                defer gpa.free(basename);

                term.println("{s}", .{basename});
            },
        },
        .argz_help => |cmd| cmd.handle(),
        .nop => {},
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("util/zoto.zig");
    _ = @import("daemon/Task.zig");
}
