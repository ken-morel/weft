const std = @import("std");

const ClientInstall = @import("ClientInstall.zig");
const Project = @import("Project.zig");
const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const dotenv = @import("../util/dotenv.zig");

fn check_cycle(
    alloc: std.mem.Allocator,
    config: *const Weft,
    pipeline: *const Weft.Pipeline,
    stack: *std.ArrayList([]const u8),
) bool {
    for (stack.items) |name| {
        if (std.mem.eql(u8, name, pipeline.name))
            return true;
    }
    stack.append(alloc, pipeline.name) catch return false;
    defer _ = stack.pop();

    for (pipeline.inputs()) |input| {
        if (Weft.is_source_artifact(input))
            continue;
        for (config.pipelines) |*other| {
            if (other.produces(input)) {
                if (check_cycle(alloc, config, other, stack))
                    return true;
            }
        }
    }
    return false;
}

fn validate_env_map(
    term: *Term,
    config: *const Weft,
    inst: ClientInstall,
    env: *const dotenv.DotEnv,
    target_desc: []const u8,
) usize {
    var missing: usize = 0;
    for (config.required_env) |key| {
        var found = env.get(key) != null or inst.env.get(key) != null;
        if (!found) {
            for (config.env) |entry| {
                if (std.mem.eql(u8, entry.@"0", key)) {
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            term.err("workspace: missing required env var '{s}' ({s})", .{ key, target_desc });
            missing += 1;
        }
    }

    for (config.pipelines) |*pipeline| {
        for (pipeline.required_env) |key| {
            var found = env.get(key) != null or inst.env.get(key) != null;
            if (!found) {
                for (pipeline.env) |entry| {
                    if (std.mem.eql(u8, entry.@"0", key)) {
                        found = true;
                        break;
                    }
                }
            }
            if (!found) {
                for (config.env) |entry| {
                    if (std.mem.eql(u8, entry.@"0", key)) {
                        found = true;
                        break;
                    }
                }
            }
            if (!found) {
                term.err("pipeline '{s}': missing required env var '{s}' ({s})", .{
                    pipeline.name,
                    key,
                    target_desc,
                });
                missing += 1;
            }
        }
    }
    return missing;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    env_name: ?[]const u8,
) !void {
    defer _ = term.flush() catch {};

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var errors: usize = 0;
    var warnings: usize = 0;

    const config = project.get_config(alloc, term, io) catch |err| {
        term.err("failed to parse weft/weft.zon: {s}", .{@errorName(err)});
        return error.InvalidConfig;
    };

    term.success("Config: weft/weft.zon syntax is valid (workspace: '{s}', pipelines: {d})", .{
        config.workspace,
        config.pipelines.len,
    });

    const sources = config.get_sources();
    var sources_valid: usize = 0;
    for (sources) |src_entry| {
        const src_name = src_entry.@"0";
        const src_path = src_entry.@"1";
        if (project.dir.access(io, src_path, .{})) |_| {
            sources_valid += 1;
        } else |_| {
            term.err("source '{s}': path '{s}' does not exist", .{ src_name, src_path });
            errors += 1;
        }
    }
    if (errors == 0 and sources.len > 0) {
        term.success("Sources: {d} source directories verified", .{sources_valid});
    }

    for (config.pipelines, 0..) |p1, idx| {
        for (config.pipelines[idx + 1 ..]) |p2| {
            if (std.mem.eql(u8, p1.name, p2.name)) {
                term.err("duplicate pipeline name found: '{s}'", .{p1.name});
                errors += 1;
            }
        }
    }

    var cycle_stack: std.ArrayList([]const u8) = .empty;
    defer cycle_stack.deinit(alloc);

    for (config.pipelines) |*pipeline| {
        for (pipeline.inputs()) |input| {
            if (Weft.is_source_artifact(input)) {
                if (std.mem.startsWith(u8, input, "src.")) {
                    const req_src = input["src.".len..];
                    var found = false;
                    for (sources) |src_entry| {
                        if (std.mem.eql(u8, src_entry.@"0", req_src)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        term.err("pipeline '{s}': input '{s}' references source '{s}' not defined in .sources", .{
                            pipeline.name,
                            input,
                            req_src,
                        });
                        errors += 1;
                    }
                }
            } else {
                var found_provider = false;
                for (config.pipelines) |*other| {
                    if (other.produces(input)) {
                        found_provider = true;
                        break;
                    }
                }
                if (!found_provider) {
                    term.err("pipeline '{s}': input '{s}' is not produced by any pipeline", .{
                        pipeline.name,
                        input,
                    });
                    errors += 1;
                }
            }
        }

        cycle_stack.clearRetainingCapacity();
        if (check_cycle(alloc, &config, pipeline, &cycle_stack)) {
            term.err("pipeline '{s}': cyclic dependency detected", .{pipeline.name});
            errors += 1;
        }

        for (pipeline.pkgs) |pkg| {
            if (pkg.len < 33 or pkg[32] != '-') {
                term.warn("pipeline '{s}': pkg '{s}' does not match nix store basename format (<32-char-hash>-<name>)", .{
                    pipeline.name,
                    pkg,
                });
                warnings += 1;
            }
        }
    }

    var scripts_checked: usize = 0;
    for (config.pipelines) |*pipeline| {
        switch (pipeline.run) {
            .nothing => continue,
            .default => {
                const script_path = try project.locate_script(alloc, io, pipeline.name);
                if (script_path) |sp| {
                    defer alloc.free(sp);
                    scripts_checked += 1;
                    var file = std.Io.Dir.openFileAbsolute(io, sp, .{}) catch |err| {
                        term.err("pipeline '{s}': failed to open script at '{s}': {s}", .{ pipeline.name, sp, @errorName(err) });
                        errors += 1;
                        continue;
                    };
                    defer file.close(io);
                    const st = file.stat(io) catch |err| {
                        term.err("pipeline '{s}': failed to stat script '{s}': {s}", .{ pipeline.name, sp, @errorName(err) });
                        errors += 1;
                        continue;
                    };
                    if ((st.permissions.toMode() & 0o111) == 0) {
                        term.warn("pipeline '{s}': script '{s}' is not executable (chmod +x recommended)", .{ pipeline.name, sp });
                        warnings += 1;
                    }
                    var header: [64]u8 = undefined;
                    const n = file.readPositionalAll(io, &header, 0) catch 0;
                    if (n < 2 or header[0] != '#' or header[1] != '!') {
                        term.warn("pipeline '{s}': script '{s}' does not have a #! shebang", .{ pipeline.name, sp });
                        warnings += 1;
                    }
                } else {
                    term.err("pipeline '{s}': no script found in weft/ matching '{s}' or '{s}.*'", .{
                        pipeline.name,
                        pipeline.name,
                        pipeline.name,
                    });
                    errors += 1;
                }
            },
            .script => |custom| {
                const script_path = try project.locate_script(alloc, io, custom);
                if (script_path) |sp| {
                    defer alloc.free(sp);
                    scripts_checked += 1;
                    var file = std.Io.Dir.openFileAbsolute(io, sp, .{}) catch |err| {
                        term.err("pipeline '{s}': failed to open custom script '{s}': {s}", .{ pipeline.name, sp, @errorName(err) });
                        errors += 1;
                        continue;
                    };
                    defer file.close(io);
                    const st = file.stat(io) catch |err| {
                        term.err("pipeline '{s}': failed to stat custom script '{s}': {s}", .{ pipeline.name, sp, @errorName(err) });
                        errors += 1;
                        continue;
                    };
                    if ((st.permissions.toMode() & 0o111) == 0) {
                        term.warn("pipeline '{s}': custom script '{s}' is not executable", .{ pipeline.name, sp });
                        warnings += 1;
                    }
                } else {
                    term.err("pipeline '{s}': custom script '{s}' not found in weft/", .{ pipeline.name, custom });
                    errors += 1;
                }
            },
        }
    }
    if (errors == 0 and scripts_checked > 0) {
        term.success("Scripts: {d} pipeline scripts verified", .{scripts_checked});
    }

    if (env_name) |target| {
        var env = dotenv.load_env(alloc, io, project.dir, target) catch |err| {
            if (err == error.EnvFileNotFound) {
                term.err("environment file for '{s}' not found (.env.{s} or {s})", .{ target, target, target });
            } else {
                term.err("failed to load environment '{s}': {s}", .{ target, @errorName(err) });
            }
            return error.ValidationFailed;
        };
        defer env.deinit(alloc);

        const desc = try std.fmt.allocPrint(alloc, "env: '{s}'", .{target});
        const missing = validate_env_map(term, &config, inst, &env, desc);
        errors += missing;
        if (missing == 0) {
            term.success("Environment: '{s}' verified", .{target});
        }
    } else {
        var env_list: std.ArrayList([]const u8) = .empty;
        defer env_list.deinit(alloc);

        var iter = project.dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind == .directory)
                continue;
            if (std.mem.startsWith(u8, entry.name, ".env.")) {
                const suffix = entry.name[".env.".len..];
                if (suffix.len > 0 and
                    !std.mem.eql(u8, suffix, "example") and
                    !std.mem.eql(u8, suffix, "sample") and
                    !std.mem.endsWith(u8, suffix, ".bak") and
                    !std.mem.endsWith(u8, suffix, ".backup"))
                {
                    try env_list.append(alloc, try alloc.dupe(u8, suffix));
                }
            }
        }

        const has_base_env = if (project.dir.access(io, ".env", .{})) |_| true else |_| false;

        if (has_base_env or env_list.items.len == 0) {
            var base_env = try dotenv.load(alloc, io, project.dir);
            defer base_env.deinit(alloc);

            const base_missing = validate_env_map(term, &config, inst, &base_env, "env: default");
            errors += base_missing;
            if (base_missing == 0) {
                term.success("Environment: default (.env) verified", .{});
            }
        }

        for (env_list.items) |name| {
            var sub_env = dotenv.load_env(alloc, io, project.dir, name) catch |err| {
                term.err("failed to load environment '{s}': {s}", .{ name, @errorName(err) });
                errors += 1;
                continue;
            };
            defer sub_env.deinit(alloc);

            const desc = try std.fmt.allocPrint(alloc, "env: '{s}'", .{name});
            const sub_missing = validate_env_map(term, &config, inst, &sub_env, desc);
            errors += sub_missing;
            if (sub_missing == 0) {
                term.success("Environment: '{s}' (.env.{s}) verified", .{ name, name });
            }
        }
    }

    if (errors > 0) {
        term.err("Validation failed with {d} error(s) and {d} warning(s)", .{ errors, warnings });
        return error.ValidationFailed;
    }

    if (env_name) |target| {
        if (warnings > 0) {
            term.warn("Validation passed with {d} warning(s) for env '{s}'", .{ warnings, target });
        } else {
            term.success("Validation passed: project is ready for deployment (env: '{s}')", .{target});
        }
    } else {
        if (warnings > 0) {
            term.warn("Validation passed with {d} warning(s)", .{warnings});
        } else {
            term.success("Validation passed: project is ready for deployment", .{});
        }
    }
}
