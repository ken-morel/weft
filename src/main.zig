const std = @import("std");
const log = std.log;
const scoped = log.scoped;
const builtin = @import("builtin");

const build = @import("build");

const ClientInstall = @import("client/ClientInstall.zig");
const cmd_artifact = @import("client/cmd_artifact.zig");
const cmd_cache = @import("client/cmd_cache.zig");
const cmd_check = @import("client/cmd_check.zig");
const cmd_kill = @import("client/cmd_kill.zig");
const cmd_logs = @import("client/cmd_logs.zig");
const cmd_monitor = @import("client/cmd_monitor.zig");
const cmd_remote = @import("client/cmd_remote.zig");
const cmd_task = @import("client/cmd_task.zig");
const Deployment = @import("client/Deployment.zig");
const cmd_do = @import("client/do.zig");
const Project = @import("client/Project.zig");
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

pub const std_options: std.Options = .{
    .fmt_max_depth = 10,
};

const Argz = union(enum) {
    pub const doc =
        \\Weft, a deployment tool
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
        ipc: union(enum) {
            pub const hidden = true;
            reload_keys: struct {},
        },
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
            const doc_remote = "The remote to pull the cache from";
            const doc_cache = "The name of the cache to pull from the remote. Ommit to pull all caches stored on the remote for this workspace";

            remote: []const u8,
            cache: ?[]const u8 = null,
        },
        push: struct {
            const doc = "Push one or more caches from a remote";
            const doc_remote = "The remote to push the cache to";
            const doc_cache = "The name of the cache to push to the remote. Ommiting to push all caches in $(weft cache path $remote) to the remote for this workspace";

            remote: []const u8,
            cache: ?[]const u8 = null,
        },
        path: struct {
            const doc = "Get the path where a cache would be stored";
            const doc_remote = "The remote name";
            const doc_cache = "The cache name, ommiting this gives the root path for all caches";

            remote: []const u8,
            cache: ?[]const u8 = null,
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
            pub const doc_step = "The target spec to kill can be <pipeline>, <remote>.<pipeline>, or <mode>:<remote>.<pipeline>";
            pub const doc_deployment = "The deployment id (defaults to latest)";

            step: []const u8,
            deployment: ?[]const u8 = null,
        },
        logs: struct {
            pub const doc = "Get the logs for a running/completed pipeline";
            pub const doc_step = "The target spec to follow can be <pipeline>, <remote>.<pipeline>, or <mode>:<remote>.<pipeline>";
            pub const doc_deployment = "The deployment id to follow (defaults to latest)";

            step: []const u8,
            deployment: ?[]const u8 = null,
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
    },
    decode: struct {
        pub const doc = "Decode and pretty print a zoto-encoded binary file or stdin";
        pub const doc_file = "The file to decode. Default to '-' for stdin";
        file: []const u8 = "-",
    },
    argz_help: argz.Help("weft", @This()),
    nop: struct {
        pub const doc = "nop";
    },
};

pub fn main(minimal: std.process.Init.Minimal) !void {
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
                clinternal.reload_keys(io);
            },
            .ipc => |i| switch (i) {
                .reload_keys => {
                    clinternal.reload_keys(io);
                },
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
        .check => {
            const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
            defer project_dir.close(io);
            const project = try Project.open_leaky(alloc, io, project_dir);

            try cmd_check.run(gpa, io, project);
        },
        .do => |cmd| {
            const targets: []Step = try gpa.alloc(Step, cmd.targets.len);
            defer gpa.free(targets);
            var last_mode: []const u8 = "default";
            for (cmd.targets, targets) |name, *tgt| {
                tgt.* = try .parse_target(name, last_mode);
                last_mode = tgt.mode;
            }

            const installation: ClientInstall = try .init(gpa, io, &environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
            defer project_dir.close(io);
            const project = try Project.open_leaky(alloc, io, project_dir);

            return cmd_do.run(gpa, io, &term, project, &installation, .{
                .start = .{
                    .targets = targets,
                },
            }, &environ_map);
        },
        .@"resume" => |cmd| {
            const installation: ClientInstall = try .init(gpa, io, &environ_map);
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
                    log.err("no deployments found in .weft", .{});
                    return error.NoDeployments;
                };

            return cmd_do.run(gpa, io, &term, project, &installation, .{ .retry = resume_id }, &environ_map);
        },
        .artifact => |cmd| {
            const installation: ClientInstall = try .init(gpa, io, &environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
            defer project_dir.close(io);
            const project = try Project.open_leaky(alloc, io, project_dir);

            return switch (cmd) {
                .pull => |c| cmd_artifact.run(
                    gpa,
                    io,
                    &term,
                    project,
                    &installation,
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
                    &installation,
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
            const installation: ClientInstall = try .init(gpa, io, &environ_map);
            const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
            defer project_dir.close(io);
            const project = try Project.open_leaky(alloc, io, project_dir);
            //TODO: Find a better way to non-repeat, maybe forcing it to be one type and represent all of
            // them in the same way
            const config = try project.get_config_leaky(alloc, io);
            const cache = switch (cmd) {
                .pull => |c| c.cache,
                .push => |c| c.cache,
                .path => |c| c.cache,
            };
            const caches = if (cache) |c|
                &.{c}
            else caches: {
                var keep: std.ArrayList([]const u8) = .empty;
                defer keep.deinit(gpa);
                for (config.pipelines) |p|
                    for (p.keep) |k|
                        for (keep.items) |i|
                            if (std.mem.eql(u8, i, k.@"0"))
                                break
                            else
                                try keep.append(gpa, k.@"0");
                break :caches try keep.toOwnedSlice(alloc);
            };
            try switch (cmd) {
                .pull => |c| cmd_cache.run(
                    gpa,
                    io,
                    &term,
                    project,
                    config,
                    &installation,
                    .pull,
                    caches,
                    c.remote,
                    &environ_map,
                ),
                .push => |c| cmd_cache.run(
                    gpa,
                    io,
                    &term,
                    project,
                    config,
                    &installation,
                    .push,
                    caches,
                    c.remote,
                    &environ_map,
                ),
                .path => |c| cmd_cache.path(
                    gpa,
                    io,
                    &term,
                    project,
                    c.remote,
                    c.cache,
                ),
            };
        },
        .task => |cmd| switch (cmd) {
            .spawn => |s| {
                const installation: ClientInstall = try .init(gpa, io, &environ_map);
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
                    &installation,
                    target,

                    s.deployment,
                    &environ_map,
                );
            },
            .kill => |k| {
                const installation: ClientInstall = try .init(gpa, io, &environ_map);
                const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
                defer project_dir.close(io);
                const project = try Project.open_leaky(alloc, io, project_dir);

                const target: Step = Step.parse_target(k.step, "default") catch |e| {
                    log.err("Invalid target: {any}: '{s}':", .{ e, k.step });
                    return e;
                };

                return cmd_kill.run(gpa, io, project, &installation, target, k.deployment, &environ_map);
            },
            .logs => |l| {
                const installation: ClientInstall = try .init(gpa, io, &environ_map);
                const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
                defer project_dir.close(io);
                const project = try Project.open_leaky(alloc, io, project_dir);

                const target: Step = Step.parse_target(l.step, "default") catch |e| {
                    log.err("Invalid target: {any}: '{s}':", .{ e, l.step });
                    return e;
                };

                return cmd_logs.run(gpa, io, project, &installation, target, l.deployment, &environ_map);
            },
        },
        .remote => |r| switch (r) {
            .register => |reg| {
                const installation: ClientInstall = try .init(gpa, io, &environ_map);
                return cmd_remote.register(
                    gpa,
                    io,
                    &installation,
                    reg.ssh,
                    reg.pubkey,
                );
            },
            .install => |inst_arg| {
                const installation: ClientInstall = try .init(gpa, io, &environ_map);
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
                const installation: ClientInstall = try .init(gpa, io, &environ_map);
                if (std.mem.eql(u8, remote_name, "local")) {
                    return cmd_monitor.run(gpa, io, &term, &installation, null, Weft.remote_local, &environ_map);
                } else if (std.mem.containsAtLeastScalar(u8, cmd.remote, ':', 1)) {
                    _ = argz.SocketAddr.argz_parse(gpa, null, cmd.remote) catch |e| {
                        log.err("Invalid ip address: {any}", .{e});
                        return error.InvalidIpAddress;
                    };
                    return cmd_monitor.run(gpa, io, &term, &installation, null, .{ "remote", remote_name, "" }, &environ_map);
                } else {
                    const project_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
                    defer project_dir.close(io);
                    const project = try Project.open_leaky(alloc, io, project_dir);
                    const config = try project.get_config_leaky(alloc, io);
                    const remote: Weft.Remote = for (config.remotes) |rem| {
                        if (std.mem.eql(u8, rem.@"0", remote_name))
                            break rem;
                    } else {
                        log.err("Remote '{s}' not found", .{remote_name});
                        return error.RemoteNotFound;
                    };
                    return cmd_monitor.run(gpa, io, &term, &installation, project, remote, &environ_map);
                }
            },
        },
        .key => {
            const installation: ClientInstall = try .init(gpa, io, &environ_map);

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
