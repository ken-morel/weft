const std = @import("std");
const log = std.log;
const scoped = log.scoped;
const builtin = @import("builtin");

const build = @import("build");

const ClientInstall = @import("client/ClientInstall.zig");
const cmd_artifact = @import("client/cmd_artifact.zig");
const cmd_cache = @import("client/cmd_cache.zig");
const cmd_check = @import("client/cmd_check.zig");
const cmd_env = @import("client/cmd_env.zig");
const cmd_init = @import("client/cmd_init.zig");
const cmd_kill = @import("client/cmd_kill.zig");
const cmd_logs = @import("client/cmd_logs.zig");
const cmd_monitor = @import("client/cmd_monitor.zig");
const cmd_remote = @import("client/cmd_remote.zig");
const cmd_task = @import("client/cmd_task.zig");
const Deployment = @import("client/Deployment.zig");
const cmd_do = @import("client/do.zig");
const Project = @import("client/Project.zig");
const Remote = @import("client/Remote.zig");
const Step = @import("client/Step.zig");
const clinternal = @import("daemon/clinternal.zig");
const Daemon = @import("daemon/Daemon.zig");
const DaemonInstall = @import("daemon/DaemonInstall.zig");
const Task = @import("daemon/Task.zig");
const decode = @import("domain/decode.zig");
const proto = @import("domain/proto.zig");
const Term = @import("domain/Term.zig");
const Weft = @import("domain/Weft.zig");
const nix = @import("nix/nix.zig");
const supervisor = @import("supervisor/supervisor.zig");
const argz = @import("util/argz.zig");
const Monitor = @import("util/Monitor.zig");
const sizes = @import("util/sizes.zig");

const include_daemon = builtin.target.os.tag == .linux;

pub fn logger(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [1 << 5]u8 = undefined;

    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    stderr.setColor(.bright_black) catch {};
    stderr.writer.writeAll("weft") catch {};
    stderr.setColor(switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};
    stderr.setColor(.bold) catch {};
    stderr.setColor(.dim) catch {};
    if (scope != .default)
        stderr.writer.print("{any}", .{scope}) catch {};
    stderr.writer.print(": ", .{}) catch {};
    stderr.setColor(.reset) catch {};
    stderr.writer.print(format ++ "\n", args) catch {};
}

pub const std_options: std.Options = .{
    .fmt_max_depth = 10,
    .http_enable_ssl_key_log_file = false,
    .logFn = logger,
};

const Argz = union(enum) {
    pub const doc =
        \\Weft, a deployment tool https://github.com/ken-morel/weft
    ;

    daemon: union(enum) {
        const hidden = !include_daemon;
        pub const doc = "Perform actions on the local daemon";
        install: struct {
            pub const doc = "Install the weft daemon locally, requires superuser priviledges";
            pub const doc_template = "Containerization template: <isolate>[-<scale>] (e.g. kvm-small, lxc-large, colab, vz-tiny)";
            template: ?[]const u8 = null,
        },
        run: struct {
            pub const doc = "Run the weft daemon, requires superuser priviledges";
        },
        register: struct {
            pub const doc = "Register an authorized client public key";
            key: []const u8,
        },
        reload: struct {},
    },

    supervisor: union(enum) {
        const hidden = true;
        supervise: struct {
            workspace: []const u8,
            pipeline: []const u8,
            deployment: []const u8,
            isolate: u8,
        },
        spawn: struct {
            workspace: []const u8,
            pipeline: []const u8,
            deployment: []const u8,
            isolate: u8,
        },
    },

    version: struct {
        pub const doc = "Display information about the weft build";
    },
    init: struct {
        pub const doc = "Initialize a new weft project in the current directory";
    },
    check: struct {
        pub const doc = "Validate weft.zon";
    },
    key: struct {
        pub const doc = "Show the client's public key";
    },

    do: struct {
        pub const doc = "Start a deployment";
        pub const doc_targets = "The different deployment targets";

        targets: [][]const u8 = &.{},
    },
    env: struct {
        pub const doc = "Run a shell or command in one or more pipeline or environment contexts";
        pub const doc_env = "Comma-separated pipeline or environment names, optionally prefixed with <mode>:";
        pub const doc_cmds = "Command and arguments to run (pass after '--' if passing flags; defaults to $SHELL)";

        env: []const u8,
        cmds: [][]const u8 = &.{},
    },
    @"resume": struct {
        pub const doc = "Resume an existing possibly failed deployment";
        pub const doc_deployment = "The id of the deployment, or shortened id containing the last unique letters of the deployment id (defaults to latest)";

        deployment: ?[]const u8 = null,
    },
    artifact: union(enum) {
        pub const doc = "Transfer artifacts to and from remotes";

        pull: struct {
            pub const doc = "Fetch the specified artifact";
            pub const doc_name = "The artifact name to pull from remote";
            pub const doc_remote = "The remote to pull from, defaults to 'local'";
            pub const doc_deployment = "The deployment id to pull artifact from, default to latest deployment";

            name: []const u8,
            remote: []const u8 = "local",
            deployment: ?[]const u8 = null,
        },
        push: struct {
            pub const doc = "Push the specified artifact";
            pub const doc_name = "The artifact/source name to push to remote";
            pub const doc_remote = "The remote name to push to, defaults to 'local'";
            pub const doc_deployment = "The deployment specifier, defaults to the latest deployment.";

            name: []const u8,
            remote: []const u8 = "local",
            deployment: ?[]const u8 = null,
        },
        register: struct {
            pub const doc = "Register an artifact in a deployment and print its expected path";
            pub const doc_name = "The artifact name to register";
            pub const doc_remote = "The remote to record as holding the artifact, defaults to 'local'";
            pub const doc_deployment = "The deployment to register the artifact in, defaults to the latest deployment";

            name: []const u8,
            remote: []const u8 = "local",
            deployment: ?[]const u8 = null,
        },
        path: struct {
            pub const doc = "Print the expected path of an artifact in a deployment";
            pub const doc_name = "The artifact name";
            pub const doc_deployment = "The deployment the artifact belongs to, defaults to the latest deployment";

            name: []const u8,
            deployment: ?[]const u8 = null,
        },
    },
    cache: union(enum) {
        pub const doc = "Interact with workspace caches on a remote";
        pull: struct {
            const doc = "Pull one or more caches from a remote";
            const doc_source = "The remote[.cache] to pull the cache from, not specifying a cache pulls all the caches";

            source: []const u8,
        },
        push: struct {
            const doc = "Push one or more caches from a remote";
            const doc_source = "The remote[.cache] to load the cache from locally";
            const doc_dest = "The remote[.cache] to push the cache to";

            source: []const u8,
            dest: ?[]const u8 = null,
        },
        path: struct {
            const doc = "Get the path where a cache would be stored";
            const doc_source = "The remote[.cache] name, omit cache to output remote caches folder";

            source: []const u8,
        },
    },
    task: union(enum) {
        pub const doc = "Perform actions on a task";

        spawn: struct {
            pub const doc = "Spawn a single pipeline in a deployment without touching its targets";
            pub const doc_step = "The target spec to spawn can be <pipeline>, <remote>.<pipeline>, or <mode>:<remote>.<pipeline>";
            pub const doc_deployment = "The deployment matcher for the deployment to spawn the pipeline in, default to the latest deployment";

            step: []const u8,
            deployment: ?[]const u8 = null,
        },
        kill: struct {
            pub const doc = "Kill a deployment or a specific pipeline in a deployment";
            pub const doc_step = "The target spec to kill can be <pipeline> or <remote>.<pipeline>";
            pub const doc_deployment = "The deployment id (defaults to latest)";

            step: []const u8,
            deployment: ?[]const u8 = null,
        },
        logs: struct {
            pub const doc = "Get the logs for a running/completed pipeline";
            pub const doc_step = "The target spec to follow can be <pipeline> or <remote>.<pipeline>";
            pub const doc_deployment = "The deployment id to follow (defaults to latest)";
            pub const doc_from = "Byte offset to start streaming logs from (defaults to 0)";

            step: []const u8,
            deployment: ?[]const u8 = null,
            from: u64 = 0,
        },
    },

    remote: union(enum) {
        pub const doc = "Perform actions on a remote";

        register: struct {
            pub const doc = "Register a client public key to the remote daemon over ssh";
            pub const doc_ssh = "The ssh address of the remote (e.g. user@host:22)";
            pub const doc_pubkey = "Optional client public key (hex), defaults to local client key";

            ssh: []const u8,
            pubkey: ?[]const u8 = null,
        },
        install: struct {
            pub const doc = "Install weft daemon on a remote via ssh and register the client";
            pub const doc_ssh = "The ssh address of the remote (e.g. user@host:22)";
            pub const doc_weft_addr = "The external weft address (host:port)";
            pub const doc_extra = "Extra arguments to pass to the install command";

            ssh: []const u8,
            extra: [][]const u8 = &.{},
        },
        monitor: struct {
            pub const doc = "Monitor a remote";
            pub const doc_remote = "The remote name to monitor or it's 'ip:[port]' tuple. Follows 'local' by default.";

            remote: []const u8 = "local",
        },
    },

    nix: union(enum) {
        pub const doc = "Perform nix operations";
        search: struct {
            pub const doc = "Search for a nix package";

            query: []const u8,
        },
        query: struct {
            pub const doc = "Query releases information about a specific package";

            name: []const u8,
        },
        info: struct {
            pub const doc = "Fetch the narinfo of a nix package and display it as yaml";
            pub const doc_pkg = "The package id, as <hash>-<name>, or just the 32 character hash";

            pkg: []const u8,
        },
    },
    decode: struct {
        pub const doc = "Decode and pretty print a zoto-encoded binary file or stdin";
        pub const doc_file = "The file to decode. Default to '-' for stdin";
        file: []const u8 = "-",
    },
    argz_help: argz.Help("weft", Argz),
    nop: struct {
        pub const doc = "nop";
    },
};

pub fn main(minimal: std.process.Init.Minimal) !void {
    // make sure client connection subprocesses get killed
    // also affects the daemon though, duh
    // _ = std.os.linux.prctl(
    //     @backingInt(std.os.linux.PR.SET_PDEATHSIG),
    //     @backingInt(std.os.linux.SIG.TERM),
    //     0,
    //     0,
    //     0,
    // );

    var allocator = switch (builtin.mode) {
        inline .debug, .safe => std.heap.SafeAllocator.init(std.heap.page_allocator, .{
            .check_write_after_free = true,
            .stack_trace_frames = 11,
        }),
        // maybe use smpallocator
        inline .fast, .small => std.heap.SafeAllocator.init(std.heap.page_allocator, .{
            .check_write_after_free = false,
            .stack_trace_frames = 1,
        }),
    };
    const gpa = allocator.allocator();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const alloc = arena.allocator();
    const args = try minimal.args.toSlice(alloc);

    var environ_map = try minimal.environ.createMap(gpa);
    defer environ_map.deinit();

    var threaded: std.Io.Threaded = .init(gpa, .{
        .stack_size = 10 << 20, // just 1mb stack
        .environ = minimal.environ,
    });
    defer threaded.deinit();

    const io = threaded.io();

    var term = try Term.init(gpa, io);
    defer {
        _ = term.flush() catch {};
        term.deinit(gpa, io);
    }

    const parsed = argz.parse(Argz, alloc, io, args[1..]) catch |err| {
        log.err("failed to parse arguments: {any}; run `weft help` for help", .{err});
        return err;
    };

    switch (parsed) {
        .version => {
            const version_str = std.fmt.comptimePrint(
                "Weft v{s}#{s}.{s}",
                .{ // so that we can inspect this directly from binary
                    comptime build.version_str,
                    comptime &std.fmt.hex(proto.hash),
                    comptime @tagName(builtin.mode),
                },
            );

            term.println("{s}", .{version_str});
        },

        .daemon => |d| if (include_daemon) switch (d) {
            .install => |i| {
                try DaemonInstall.install(gpa, io, i.template);
            },
            .run => {
                const installation: DaemonInstall = try .init(io);
                var daemon = try Daemon.init(gpa, io, installation);
                defer daemon.deinit();
                return daemon.run();
            },
            .register => |r| {
                var key: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&key, r.key) catch |err| {
                    log.err("Invalid client public key: {any}", .{err});
                    return err;
                };
                try DaemonInstall.add_key(io, key);
                clinternal.reload(io);
            },
            .reload => {
                clinternal.reload(io);
            },
        },
        .supervisor => |s| if (include_daemon) switch (s) {
            .supervise => |a| {
                const task: Task = .{ .id = .{
                    .workspace = a.workspace,
                    .deployment = try .parse(a.deployment),
                    .pipeline = a.pipeline,
                } };
                const isolate: DaemonInstall.Isolate = @fromBackingInt(a.isolate);
                return supervisor.supervise(gpa, io, task, isolate);
            },
            .spawn => |a| {
                const task: Task = .{ .id = .{
                    .workspace = a.workspace,
                    .deployment = try .parse(a.deployment),
                    .pipeline = a.pipeline,
                } };
                const isolate: DaemonInstall.Isolate = @fromBackingInt(a.isolate);
                return supervisor.spawner(gpa, io, task, isolate);
            },
        },
        .init => try cmd_init.run(gpa, io),
        .check => {
            const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
            defer project_dir.close(io);
            const project = try Project.open_leaky(alloc, io, project_dir);
            var inst = ClientInstall.init(gpa, alloc, io, &environ_map) catch null;

            try cmd_check.run(gpa, io, project, if (inst) |*i| i else null);
        },
        .do => |cmd| {
            var targets: std.ArrayList(Step) = try .initCapacity(gpa, cmd.targets.len);
            defer targets.deinit(gpa);
            var last_mode: []const u8 = "default";
            var pending_barrier = false;
            for (cmd.targets) |name| {
                if (std.mem.eql(u8, name, "-")) {
                    pending_barrier = true;
                    continue;
                }
                var tgt = try Step.parse_target(name, last_mode);
                tgt.barrier = pending_barrier;
                pending_barrier = false;
                last_mode = tgt.mode;
                targets.appendAssumeCapacity(tgt);
            }

            const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
            defer project_dir.close(io);
            const project = try Project.open_leaky(alloc, io, project_dir);

            return cmd_do.run(gpa, io, &term, project, installation, .{
                .start = .{
                    .targets = targets.items,
                },
            }, &environ_map);
        },
        .env => |cmd| {
            const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
            defer project_dir.close(io);
            const project = try Project.open_leaky(alloc, io, project_dir);

            return cmd_env.run(
                gpa,
                io,
                &term,
                project,
                installation,
                cmd.env,
                cmd.cmds,
                &environ_map,
            );
        },
        .@"resume" => |cmd| {
            const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
            defer project_dir.close(io);
            const project = try Project.open_leaky(alloc, io, project_dir);

            const resume_id = if (cmd.deployment) |dep_arg|
                project.find_deployment_id(io, dep_arg) catch {
                    log.err("deployment '{s}' not found or ambiguous", .{dep_arg});
                    return error.InvalidDeploymentId;
                }
            else
                try project.latest_deployment_id(io) orelse {
                    log.err("no deployments found in weft/do", .{});
                    return error.NoDeployments;
                };

            return cmd_do.run(gpa, io, &term, project, installation, .{ .retry = resume_id }, &environ_map);
        },
        .artifact => |cmd| {
            const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
            defer project_dir.close(io);
            const project = try Project.open_leaky(alloc, io, project_dir);

            return switch (cmd) {
                .pull => |c| cmd_artifact.run(
                    gpa,
                    io,
                    &term,
                    project,
                    installation,
                    .pull,
                    c.name,
                    c.remote,
                    c.deployment,
                    &environ_map,
                ),
                .push => |c| cmd_artifact.run(
                    gpa,
                    io,
                    &term,
                    project,
                    installation,
                    .push,
                    c.name,
                    c.remote,
                    c.deployment,
                    &environ_map,
                ),
                .register => |c| cmd_artifact.register(
                    gpa,
                    io,
                    &term,
                    project,
                    c.name,
                    c.remote,
                    c.deployment,
                ),
                .path => |c| cmd_artifact.path(
                    gpa,
                    io,
                    &term,
                    project,
                    c.name,
                    c.deployment,
                ),
            };
        },
        .cache => |cmd| {
            const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
            defer project_dir.close(io);
            const project = try Project.open_leaky(alloc, io, project_dir);
            //TODO: Find a better way to non-repeat, maybe forcing it to be one type and represent all of
            // them in the same way
            const config = try project.get_config_leaky(alloc, io);
            try switch (cmd) {
                .pull => |c| cmd_cache.pull(
                    gpa,
                    io,
                    &term,
                    project,
                    config,
                    installation,
                    c.source,
                    &environ_map,
                ),
                .push => |c| cmd_cache.push(
                    gpa,
                    io,
                    &term,
                    project,
                    config,
                    installation,
                    c.source,
                    c.dest,
                    &environ_map,
                ),
                .path => |c| cmd_cache.path(
                    gpa,
                    io,
                    &term,
                    project,
                    c.source,
                ),
            };
        },
        .task => |cmd| switch (cmd) {
            .spawn => |s| {
                const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);
                const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
                defer project_dir.close(io);
                const project = try Project.open_leaky(alloc, io, project_dir);

                const target: Step = Step.parse_target(s.step, "default") catch |e| {
                    log.err("Invalid target: {any}: '{s}':", .{ e, s.step });
                    return e;
                };

                return cmd_task.spawn(
                    gpa,
                    io,
                    &term,
                    project,
                    installation,
                    target,

                    s.deployment,
                    &environ_map,
                );
            },
            .kill => |k| {
                const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);
                const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
                defer project_dir.close(io);
                const project = try Project.open_leaky(alloc, io, project_dir);

                const target: Step = Step.parse_target(k.step, "default") catch |e| {
                    log.err("Invalid target: {any}: '{s}':", .{ e, k.step });
                    return e;
                };

                return cmd_kill.run(gpa, io, project, installation, target, k.deployment, &environ_map);
            },
            .logs => |l| {
                const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);
                const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
                defer project_dir.close(io);
                const project = try Project.open_leaky(alloc, io, project_dir);

                const target: Step = Step.parse_target(l.step, "default") catch |e| {
                    log.err("Invalid target: {any}: '{s}':", .{ e, l.step });
                    return e;
                };

                return cmd_logs.run(gpa, io, project, installation, target, l.deployment, l.from, &environ_map);
            },
        },
        .remote => |r| switch (r) {
            .register => |reg| {
                const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);
                return cmd_remote.register(
                    gpa,
                    io,
                    &installation,
                    reg.ssh,
                    reg.pubkey,
                );
            },
            .install => |inst_arg| {
                const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);
                return cmd_remote.install(
                    gpa,
                    io,
                    &installation,
                    inst_arg.ssh,
                    inst_arg.extra,
                );
            },
            .monitor => |cmd| {
                const remote_name = cmd.remote;
                const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);

                const project = Project.open_leaky(alloc, io, .cwd()) catch null;

                const config = if (project) |p|
                    p.get_config_leaky(alloc, io) catch null
                else
                    null;

                const remote = remote: {
                    if (Step.is_valid_name(cmd.remote)) {
                        const remotes = try Remote.resolve_remotes_leaky(gpa, alloc, io, config, installation, project);
                        for (remotes) |remote|
                            if (std.mem.eql(u8, remote.name, cmd.remote))
                                break :remote remote;
                    } else break :remote Remote{
                        .name = "weft",
                        .address = try .resolve_leaky(gpa, alloc, io, cmd.remote, installation, project),
                        .groups = "",
                    };

                    log.err("Remote '{s}' not found", .{remote_name});
                    return error.RemoteNotFound;
                };
                return cmd_monitor.run(
                    gpa,
                    io,
                    &term,
                    installation,
                    remote,
                    &environ_map,
                );
            },
        },
        .key => {
            const installation: ClientInstall = try .init(gpa, alloc, io, &environ_map);

            const hex = std.fmt.bytesToHex(installation.identity.public_key(), .upper);
            term.print("{s}", .{&hex});
            return;
        },

        .nix => |n| switch (n) {
            .search => |s| {
                var client: std.http.Client = .{
                    .allocator = gpa,
                    .io = io,
                };
                const res = try nix.devbox.search(gpa, &client, s.query, .{});
                defer res.deinit();
                for (res.value.results) |r| {
                    term.println("- name: {s}", .{r.name});
                    if (r.summary) |summary|
                        if (summary.len > 0)
                            term.println("  summary: {s}", .{summary});
                }
            },
            .query => |q| {
                var client: std.http.Client = .{
                    .allocator = gpa,
                    .io = io,
                };
                defer client.deinit();

                const res = nix.devbox.query_package(gpa, &client, q.name) catch |err| {
                    if (err == error.PackageNotFound)
                        log.err("package '{s}' not found on devbox", .{q.name});
                    return err;
                };
                defer res.deinit();
                const pkg = res.value;

                term.println("name: {s}\nsummary: {?s}\nhomepage: {?s}\nlicense: {?s}\nreleases:", .{
                    pkg.name, pkg.summary, pkg.homepage_url, pkg.license,
                });
                const system = nix.devbox.current.system;
                for (pkg.releases) |r| {
                    const date = r.last_updated orelse "";
                    term.println("  {s}: # {s}", .{ r.version, date[0..@min(date.len, 10)] });
                    for (r.platforms) |p| {
                        const is_current = std.mem.eql(u8, system, p.system);
                        term.println("    {s}:{s}", .{ p.system, if (is_current) " # current" else "" });
                        for (p.outputs orelse &.{}) |o|
                            term.println("      {s}: {s}", .{ o.name, o.basename() });
                    }
                }
            },
            .info => |i| {
                var size_buf: [32]u8 = undefined;
                if (i.pkg.len < 32) {
                    log.err("invalid package id '{s}': expected at least a 32 character hash", .{i.pkg});
                    return error.InvalidHash;
                }
                var client: std.http.Client = .{
                    .allocator = gpa,
                    .io = io,
                };
                defer client.deinit();

                const info = nix.NarInfo.fetch(
                    gpa,
                    &client,
                    i.pkg[0..32],
                ) catch |err| {
                    if (err == error.InvalidHttpResponse)
                        log.err("no narinfo found for '{s}' on cache.nixos.org", .{i.pkg[0..32]});
                    return err;
                };
                defer info.deinit(gpa);

                term.println("store_path: \"{s}\"", .{info.store_path});
                term.println("url: \"{s}\"", .{info.url});
                term.println("compression: \"{s}\"", .{info.compression});
                if (info.file_hash) |h|
                    term.println("file_hash: \"{s}\"", .{h});
                term.println("file_size: {d} # {s}", .{ info.file_size, sizes.format_bytes(&size_buf, info.file_size) catch "" });
                term.println("nar_hash: \"{s}\"", .{info.nar_hash});
                term.println("nar_size: {d} # {s}", .{ info.nar_size, sizes.format_bytes(&size_buf, info.nar_size) catch "" });
                if (info.deriver) |d|
                    term.println("deriver: \"{s}\"", .{d});
                if (info.has_deps()) {
                    term.println("references:", .{});
                    var deps = info.deps();
                    while (deps.next()) |dep|
                        if (dep.len > 0)
                            term.println("  - \"{s}\"", .{dep});
                } else term.println("references: []", .{});
                if (info.sig) |sig|
                    term.println("sig: \"{s}\"", .{sig});
            },
        },
        .decode => |d| {
            const content = if (std.mem.eql(u8, d.file, "-")) in: {
                var buf: [4096]u8 = undefined;
                var allocating: std.Io.Writer.Allocating = .init(gpa);
                defer allocating.deinit();

                var stdin_reader = std.Io.File.stdin().readerStreaming(io, &buf);
                _ = try allocating.writer.sendFileReadingAll(&stdin_reader, .unlimited);
                break :in try allocating.toOwnedSlice();
            } else try std.Io.Dir.cwd().readFileAlloc(io, d.file, gpa, .unlimited);
            defer gpa.free(content);

            try decode.decode_and_print(alloc, content, term.writer());
        },
        .argz_help => |cmd| cmd.handle(),
        .nop => {},
    }
}
