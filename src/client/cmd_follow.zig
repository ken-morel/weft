const std = @import("std");

const proto = @import("../domain/proto.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const format_bytes = @import("../util/sizes.zig").format_bytes;
const Connection = @import("../wire/Connection.zig");
const Client = @import("Client.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Remote = @import("Remote.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    pipeline_spec: []const u8,
    deployment_spec: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const dep_id = if (deployment_spec) |dep_str|
        project.find_deployment_id(io, dep_str) catch |err| {
            term.err("deployment '{s}' not found or ambiguous: {any}", .{ dep_str, err });
            return error.InvalidDeploymentId;
        }
    else
        try project.latest_deployment_id(io) orelse {
            term.err("no deployments found in .weft", .{});
            return error.NoDeployments;
        };

    var deployment = project.load_deployment(alloc, io, dep_id) catch |err| {
        term.err("failed to load deployment: {any}", .{err});
        return err;
    };

    const remotes = try inst.get_remotes(alloc, io, term);

    const pipeline_name = if (pipeline_spec.len > 0 and pipeline_spec[0] == '.')
        pipeline_spec[1..]
    else
        pipeline_spec;

    _ = deployment.config.get_pipeline(pipeline_name) orelse {
        term.err("pipeline '{s}' not found in deployment {s}", .{ pipeline_name, &deployment.id.to_string() });
        return error.InvalidPipeline;
    };

    const remote_name = for (deployment.targets) |target| {
        if (std.mem.eql(u8, target.pipeline, pipeline_name))
            break target.remote;
    } else "local";

    const remote: *const Remote = for (remotes) |*rem| {
        if (std.mem.eql(u8, rem.get_name(), remote_name))
            break rem;
    } else {
        term.err("remote '{s}' not found in configuration", .{remote_name});
        return error.InvalidRemote;
    };

    const task_key = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ remote_name, pipeline_name });
    defer alloc.free(task_key);

    const task_id: proto.task.Id = .{
        .workspace = deployment.config.workspace,
        .deployment = deployment.id,
        .pipeline = pipeline_name,
    };

    var remote_log_offset: u64 = 0;

    const buffer = try alloc.alloc(u8, Connection.max_packet_size);
    defer alloc.free(buffer);

    var rendered_lines: u16 = 0;
    var cpu_ms: ?u64 = null;
    var cpu_pct: ?f32 = null;
    var memory_bytes: ?u64 = null;
    var prev_cpu_usec: ?u64 = null;
    var last_poll_time: ?std.Io.Timestamp = null;

    var client = Client.connect(alloc, io, try remote.get_address(), &try remote.get_token()) catch |e| {
        term.err("connection to remote '{s}' failed: {any}", .{ remote_name, e });
        return e;
    };
    defer client.destroy(alloc, io);

    while (true) {
        client.conn.send_object(buffer, proto.Request, .task_poll) catch |e| {
            term.err("failed to send task_poll request: {any}", .{e});
            return e;
        };
        client.conn.send_object(buffer, proto.task.poll.Req, .{
            .header = .{
                .tasks = &.{.{
                    .task = task_id,
                    .logs_offset = remote_log_offset,
                }},
            },
        }) catch |e| {
            term.err("failed to send poll payload: {any}", .{e});
            return e;
        };

        var is_running = false;
        var final_status: ?union(enum) { success, failed: u16, not_found } = null;

        while (true) {
            const reply = client.conn.recv_object(alloc, proto.Res(proto.task.poll.Res)) catch |e| {
                term.err("failed to receive poll reply: {any}", .{e});
                return e;
            };
            const res = reply catch |e| {
                term.err("poll error from remote: {any}", .{e});
                return e;
            };

            switch (res) {
                .item => |item| {
                    if (item.logs) |logs| {
                        if (logs.data.len > 0) {
                            if (term.is_tty and rendered_lines > 0) {
                                term.move_up(rendered_lines);
                                term.clear_to_end();
                                rendered_lines = 0;
                            }

                            try term.writer().writeAll(logs.data);
                            try term.flush();
                        }
                        remote_log_offset = logs.end_offset;
                        alloc.free(logs.data);
                    }

                    if (item.usage) |u| {
                        const now = std.Io.Clock.now(.real, io);
                        memory_bytes = u.memory_bytes;
                        cpu_ms = u.cpu_usec / 1000;
                        if (last_poll_time) |last_t| {
                            const dt_ns = now.nanoseconds - last_t.nanoseconds;
                            if (dt_ns > 50_000_000 and prev_cpu_usec != null) {
                                const dt_usec = @divTrunc(dt_ns, 1000);
                                const delta_usec = u.cpu_usec -| prev_cpu_usec.?;
                                cpu_pct = @as(f32, @floatFromInt(delta_usec)) * 100.0 / @as(f32, @floatFromInt(dt_usec));
                            }
                        }
                        prev_cpu_usec = u.cpu_usec;
                        last_poll_time = now;
                    }

                    switch (item.status) {
                        .running => {
                            is_running = true;
                        },
                        .success => {
                            final_status = .success;
                        },
                        .failed => |code| {
                            final_status = .{ .failed = code };
                        },
                        .not_found => {
                            final_status = .not_found;
                        },
                    }
                },
                .footer => break,
            }
        }

        if (final_status) |status| {
            if (term.is_tty and rendered_lines > 0) {
                term.move_up(rendered_lines);
                term.clear_to_end();
                rendered_lines = 0;
            }

            switch (status) {
                .success => {
                    if (term.is_tty) {
                        term.success("task {s} completed", .{task_key});
                    }
                    return;
                },
                .failed => |code| {
                    if (term.is_tty) {
                        term.err("task {s} failed with exit code {d}", .{ task_key, code });
                    }
                    return error.TaskFailed;
                },
                .not_found => {
                    if (term.is_tty) {
                        term.err("task {s} not found on daemon", .{task_key});
                    }
                    return error.TaskNotFound;
                },
            }
        }

        if (is_running and term.is_tty) {
            if (rendered_lines > 0) {
                term.move_up(rendered_lines);
                term.clear_to_end();
                rendered_lines = 0;
            }

            const term_size = term.get_size();
            const width: usize = @min(@as(usize, term_size.cols), 60);
            var rule_buf: [256]u8 = undefined;
            const char = "─";
            const count = @max(width, 10);
            var pos: usize = 0;
            for (0..count) |_| {
                if (pos + char.len <= rule_buf.len) {
                    @memcpy(rule_buf[pos .. pos + char.len], char);
                    pos += char.len;
                }
            }
            term.clear_line();
            term.styled_ln(.dim, "{s}", .{rule_buf[0..pos]});

            var stats_buf: [128]u8 = undefined;
            var stats_str: []const u8 = "";
            if (cpu_ms != null or memory_bytes != null) {
                var mem_buf: [32]u8 = undefined;
                const m_str = if (memory_bytes) |mb| format_bytes(&mem_buf, mb) else "--";
                if (cpu_pct) |pct| {
                    stats_str = std.fmt.bufPrint(&stats_buf, " (CPU: {d:.1}% / {d}ms, RAM: {s})", .{
                        pct,
                        cpu_ms orelse 0,
                        m_str,
                    }) catch "";
                } else {
                    stats_str = std.fmt.bufPrint(&stats_buf, " (CPU: {d}ms, RAM: {s})", .{
                        cpu_ms orelse 0,
                        m_str,
                    }) catch "";
                }
            }
            const color = Term.task_color(task_key);
            term.clear_line();
            term.styled_ln(color, "! {s}{s}", .{ task_key, stats_str });

            rendered_lines = 2;
            term.clear_to_end();
            try term.flush();
        }

        if (is_running) {
            try std.Io.sleep(io, .fromSeconds(1), .awake);
        } else {
            break;
        }
    }
}
