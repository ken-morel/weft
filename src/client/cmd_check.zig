const std = @import("std");
const log = std.log.scoped;

const Task = @import("../domain/Task.zig");
const Weft = @import("../domain/Weft.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Step = @import("Step.zig");

fn is_valid_mount_path(path: []const u8) bool {
    if (path.len == 0)
        return false;
    if (path[0] == '/' or path[0] == '.')
        return false;
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return false;
    }
    return true;
}

fn is_valid_relative_path(path: []const u8) bool {
    if (path.len == 0)
        return false;
    if (path[0] == '/')
        return false;
    if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, ".."))
        return false;
    if (std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../"))
        return false;
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return false;
    }
    return true;
}

fn check_cycle(
    alloc: std.mem.Allocator,
    config: Weft,
    pipeline: Weft.Pipeline,
    stack: *std.ArrayList([]const u8),
) bool {
    for (stack.items) |name|
        if (std.mem.eql(u8, name, pipeline.name))
            return true;

    stack.append(
        alloc,
        pipeline.name,
    ) catch
        return false;
    defer _ = stack.pop();

    for (pipeline.in) |input|
        if (Weft.is_source_artifact(input))
            continue
        else for (config.pipelines.items) |other|
            if (other.produces(input))
                if (check_cycle(alloc, config, other, stack))
                    return true;

    return false;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: Project,
    inst: ?*const ClientInstall,
) !void {
    const l = log(.check);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = project.get_config_leaky(alloc, io) catch |err| {
        l.err("failed to parse weft/weft.zon: {s}", .{@errorName(err)});
        return error.InvalidConfig;
    };

    var errors: usize = 0;

    if (!Step.is_valid_name(config.workspace)) {
        l.err("workspace name '{s}' is invalid (must start with a letter and contain only letters, numbers, and '-')", .{config.workspace});
        errors += 1;
    }

    const sources = config.get_sources();
    for (sources, 0..) |s1, idx|
        for (sources[idx + 1 ..]) |s2|
            if (std.mem.eql(u8, s1.@"0", s2.@"0")) {
                l.err("duplicate source name found: '{s}'", .{s1.@"0"});
                errors += 1;
            };

    for (sources) |src_entry| {
        if (!is_valid_relative_path(src_entry.@"1")) {
            l.err("source '{s}' path '{s}' must be relative (cannot start with '.' or '/')", .{ src_entry.@"0", src_entry.@"1" });
            errors += 1;
        }
        project.dir.access(io, src_entry.@"1", .{}) catch |err| {
            l.err("source '{s}' at '{s}': {any}", .{ src_entry.@"0", src_entry.@"1", err });
            errors += 1;
        };
    }

    for (config.environments.items, 0..) |e1, idx|
        for (config.environments.items[idx + 1 ..]) |e2|
            if (std.mem.eql(u8, e1.name, e2.name)) {
                l.err("duplicate environment name found: '{s}'", .{e1.name});
                errors += 1;
            };

    for (config.remotes.items, 0..) |r1, idx|
        for (config.remotes.items[idx + 1 ..]) |r2|
            if (std.mem.eql(u8, r1.name, r2.name)) {
                l.err("duplicate remote name found: '{s}'", .{r1.name});
                errors += 1;
            };

    const client_cfg = if (inst) |i|
        i.read_config_leaky(gpa, alloc, io) catch null
    else
        null;

    for (config.remotes.items) |r| {
        const raw_addr = if (r.address) |addr| addr else blk: {
            if (client_cfg) |cfg|
                if (cfg.remotes.get(r.name)) |addr|
                    break :blk addr;

            l.warn("remote '{s}': address is not specified in weft.zon and not configured in client.zon", .{r.name});
            break :blk null;
        };

        if (raw_addr) |addr|
            if (addr.len > 0 and (addr[0] == '!' or addr[0] == '~')) {
                const cmd_str = std.mem.trim(u8, addr[1..], " \t");
                var iter = std.mem.tokenizeScalar(u8, cmd_str, ' ');
                if (iter.next()) |script_name| {
                    const located = if (inst) |i|
                        (try i.locate_script(alloc, io, script_name)) != null
                    else
                        false;
                    if (!located) {
                        if (try project.locate_script(alloc, io, script_name)) |sp| {
                            alloc.free(sp);
                        } else if (project.dir.access(io, script_name, .{})) |_| {} else |_| {
                            l.err("remote '{s}': connection script '{s}' not found in client config, weft/, or project directory", .{ r.name, script_name });
                            errors += 1;
                        }
                    }
                } else {
                    l.err("remote '{s}': command is empty after '{c}'", .{ r.name, addr[0] });
                    errors += 1;
                }
            };
    }

    for (config.pipelines.items, 0..) |p1, idx|
        for (config.pipelines.items[idx + 1 ..]) |p2|
            if (std.mem.eql(u8, p1.name, p2.name)) {
                l.err("duplicate pipeline name found: '{s}'", .{p1.name});
                errors += 1;
            };

    for (config.pipelines.items, 0..) |p1, idx| {
        const p1_outs: []const []const u8 = p1.out orelse &.{p1.name};
        for (config.pipelines.items[idx + 1 ..]) |p2| {
            const p2_outs: []const []const u8 = p2.out orelse &.{p2.name};
            for (p1_outs) |out1| {
                for (p2_outs) |out2| {
                    if (std.mem.eql(u8, out1, out2)) {
                        l.err("pipelines '{s}' and '{s}' both produce output '{s}'", .{ p1.name, p2.name, out1 });
                        errors += 1;
                    }
                }
            }
        }
    }

    var cycle_stack: std.ArrayList([]const u8) = .empty;
    defer cycle_stack.deinit(alloc);

    for (config.pipelines.items) |pipeline| {
        if (!Step.is_valid_name(pipeline.name)) {
            l.err("pipeline name '{s}' is invalid (must start with a letter and contain only letters, numbers, and '-')", .{pipeline.name});
            errors += 1;
        }

        for (pipeline.in) |raw_input| {
            const input = Weft.strip_mode(null, raw_input) orelse raw_input;
            if (Weft.is_source_artifact(input)) {
                const req_src = input[1..];
                for (sources) |src_entry| {
                    if (std.mem.eql(u8, src_entry.@"0", req_src))
                        break;
                } else {
                    l.err("pipeline '{s}': input '{s}' references source '{s}' not defined in .sources", .{
                        pipeline.name,
                        raw_input,
                        req_src,
                    });
                    errors += 1;
                }
            } else {
                const produced = produced: for (config.pipelines.items) |*other| {
                    const outs = other.out orelse &.{other.name};
                    for (outs) |raw_out| {
                        const out = Weft.strip_mode(null, raw_out) orelse raw_out;
                        if (std.mem.eql(u8, out, input))
                            break :produced true;
                    }
                } else false;

                if (!produced) {
                    l.err("pipeline '{s}': input '{s}' is not produced by any pipeline", .{
                        pipeline.name,
                        raw_input,
                    });
                    errors += 1;
                }
            }
        }

        cycle_stack.clearRetainingCapacity();
        if (check_cycle(alloc, config, pipeline, &cycle_stack)) {
            l.err("pipeline '{s}': cyclic dependency detected", .{pipeline.name});
            errors += 1;
        }

        if (pipeline.on) |on_list| {
            for (on_list) |target| {
                const found = for (config.remotes.items) |r| {
                    if (Weft.remote_has_group(r, target))
                        break true;
                } else false;

                if (!found) {
                    l.err("pipeline '{s}': .on group '{s}' does not match any remote group", .{ pipeline.name, target });
                    errors += 1;
                }
            }
        }

        for (pipeline.env.uses) |env_name| {
            for (config.environments.items) |e| {
                if (std.mem.eql(u8, e.name, env_name))
                    break;
            } else {
                l.err("pipeline '{s}': referenced environment '{s}' not defined in .environments", .{ pipeline.name, env_name });
                errors += 1;
            }
        }

        for (pipeline.keep.items) |k| {
            if (!is_valid_relative_path(k.@"1")) {
                l.err("pipeline '{s}': .keep path '{s}' must be a relative path and cannot start with '.' or '/'", .{ pipeline.name, k.@"1" });
                errors += 1;
            }
        }

        for (pipeline.tune.io.mount) |m| {
            const target, const mode, const source = m;
            if (!is_valid_mount_path(target)) {
                l.err("pipeline '{s}': .mount target '{s}' must be a relative path and cannot start with '.' or '/'", .{ pipeline.name, target });
                errors += 1;
            }
            if (mode != .tmpfs and !is_valid_mount_path(source)) {
                l.err("pipeline '{s}': .mount source '{s}' must be a relative path and cannot start with '.' or '/'", .{ pipeline.name, source });
                errors += 1;
            }
        }
    }

    for (config.pipelines.items) |*pipeline|
        if (pipeline.run) |p_run|
            switch (p_run) {
                .script => |script_str| {
                    if (script_str.len == 0) {
                        l.err("pipeline '{s}': .run.script cannot be empty", .{pipeline.name});
                        errors += 1;
                    } else if (!std.mem.startsWith(u8, script_str, "#!")) {
                        l.err("pipeline '{s}': .run.script must start with a '#!' shebang", .{pipeline.name});
                        errors += 1;
                    }
                },
                .nothing => {},
                .file => |custom| {
                    if (try project.locate_script(alloc, io, custom)) |sp| {
                        defer alloc.free(sp);
                        var file = std.Io.Dir.openFileAbsolute(io, sp, .{}) catch |err| {
                            l.err("pipeline '{s}': failed to open script at '{s}': {s}", .{ pipeline.name, sp, @errorName(err) });
                            errors += 1;
                            continue;
                        };
                        defer file.close(io);

                        var header: [2]u8 = undefined;
                        _ = file.readPositionalAll(io, &header, 0) catch 0;
                        if (!std.mem.eql(u8, &header, "#!"))
                            l.warn("pipeline '{s}': script '{s}' does not have a #! shebang", .{ pipeline.name, sp });
                    } else {
                        l.err("custom script '{s}' not found in weft/ for pipeline '{s}'", .{ custom, pipeline.name });
                        errors += 1;
                    }
                },
            }
        else {
            if (try project.locate_script(alloc, io, pipeline.name)) |sp| {
                defer alloc.free(sp);
                var file = std.Io.Dir.openFileAbsolute(io, sp, .{}) catch |err| {
                    l.err("pipeline '{s}': failed to open script at '{s}': {s}", .{ pipeline.name, sp, @errorName(err) });
                    errors += 1;
                    continue;
                };
                defer file.close(io);

                var header: [2]u8 = undefined;
                _ = file.readPositionalAll(io, &header, 0) catch 0;
                if (!std.mem.eql(u8, &header, "#!"))
                    l.warn("pipeline '{s}': script '{s}' does not have a #! shebang", .{ pipeline.name, sp });
            } else {
                l.err("no script found in weft/ matching pipeline '{s}' or '{s}.*'", .{ pipeline.name, pipeline.name });
                errors += 1;
            }
        };

    for (config.modes) |mode| {
        for (config.pipelines.items) |*pipeline| {
            var p_arena: std.heap.ArenaAllocator = .init(gpa);
            defer p_arena.deinit();
            _ = Task.Spec.resolve_leaky(
                gpa,
                p_arena.allocator(),
                io,
                &config,
                pipeline,
                undefined,
                mode,
                project.env,
                "",
            ) catch undefined;
        }
    }

    if (errors > 0)
        return error.CheckFailed;
}
