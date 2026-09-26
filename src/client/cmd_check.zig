const std = @import("std");

const Term = @import("../domain/Term.zig");
const Weft = @import("../domain/Weft.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");
const Task = @import("../daemon/Task.zig");

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

    for (pipeline.inputs()) |input|
        if (Weft.is_source_artifact(input))
            continue
        else for (config.pipelines) |other|
            if (other.produces(input))
                if (check_cycle(alloc, config, other, stack))
                    return true;

    return false;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    term: *Term,
    project: Project,
    inst: ClientInstall,
    env_name: ?[]const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = project.get_config(alloc, term, io) catch |err| {
        term.err("failed to parse weft/weft.zon: {s}", .{@errorName(err)});
        return error.InvalidConfig;
    };

    const sources = config.get_sources();
    for (sources) |src_entry|
        project.dir.access(io, src_entry.@"1", .{}) catch |err|
            term.err("source '{s}' at '{s}': {any}", .{ src_entry.@"0", src_entry.@"1", err });

    for (config.pipelines, 0..) |p1, idx|
        for (config.pipelines[idx + 1 ..]) |p2|
            if (std.mem.eql(u8, p1.name, p2.name))
                term.err("duplicate pipeline name found: '{s}'", .{p1.name});

    var cycle_stack: std.ArrayList([]const u8) = .empty;
    defer cycle_stack.deinit(alloc);

    for (config.pipelines) |pipeline| {
        for (pipeline.inputs()) |input| {
            if (Weft.is_source_artifact(input)) {
                if (std.mem.startsWith(u8, input, "src.")) {
                    const req_src = input["src.".len..];
                    for (sources) |src_entry| {
                        if (std.mem.eql(u8, src_entry.@"0", req_src))
                            break;
                    } else term.err("pipeline '{s}': input '{s}' references source '{s}' not defined in .sources", .{
                        pipeline.name,
                        input,
                        req_src,
                    });
                }
            } else {
                for (config.pipelines) |*other| {
                    if (other.produces(input))
                        break;
                } else term.err("pipeline '{s}': input '{s}' is not produced by any pipeline", .{
                    pipeline.name,
                    input,
                });
            }
        }

        cycle_stack.clearRetainingCapacity();
        if (check_cycle(alloc, config, pipeline, &cycle_stack))
            term.err("pipeline '{s}': cyclic dependency detected", .{pipeline.name});

        for (pipeline.uses) |env|
            for (config.environments) |e| {
                if (std.mem.eql(u8, env, e.name))
                    break;
            } else term.err("pipeline '{s}': Invalid environment: {s}", .{ pipeline.name, env });
    }

    for (config.pipelines) |*pipeline|
        switch (pipeline.run) {
            .nothing => continue,
            .script => |lines| {
                if (lines.len == 0)
                    term.err("pipeline '{s}': .run.script cannot be empty", .{pipeline.name})
                else if (!std.mem.startsWith(u8, lines[0], "#!"))
                    term.err("pipeline '{s}': first line of .run.script must be a '#!' shebang", .{pipeline.name});
            },
            .default => {
                if (try project.locate_script(alloc, io, pipeline.name)) |sp| {
                    defer alloc.free(sp);
                    var file = std.Io.Dir.openFileAbsolute(io, sp, .{}) catch |err| {
                        term.err("pipeline '{s}': failed to open script at '{s}': {s}", .{ pipeline.name, sp, @errorName(err) });
                        continue;
                    };
                    defer file.close(io);

                    var header: [2]u8 = undefined;
                    _ = file.readPositionalAll(io, &header, 0) catch 0;
                    if (!std.mem.eql(u8, &header, "#!"))
                        term.warn("pipeline '{s}': script '{s}' does not have a #! shebang", .{ pipeline.name, sp });
                } else term.err("no script found in weft/ matching pipeline '{s}' or '{s}.*'", .{ pipeline.name, pipeline.name });
            },
            .file => |custom| {
                if (try project.locate_script(alloc, io, custom)) |sp| {
                    defer alloc.free(sp);
                    var file = std.Io.Dir.openFileAbsolute(io, sp, .{}) catch |err| {
                        term.err("pipeline '{s}': failed to open script at '{s}': {s}", .{ pipeline.name, sp, @errorName(err) });
                        continue;
                    };
                    defer file.close(io);

                    var header: [2]u8 = undefined;
                    _ = file.readPositionalAll(io, &header, 0) catch 0;
                    if (!std.mem.eql(u8, &header, "#!"))
                        term.warn("pipeline '{s}': script '{s}' does not have a #! shebang", .{ pipeline.name, sp });
                } else term.err("custom script '{s}' not found in weft/ for pipeline '{s}'", .{ custom, pipeline.name });
            },
        };

    if (env_name) |target| {
        if (config.get_environment(target) == null) {
            term.err("environment '{s}' not found in weft.zon", .{target});
            return error.ValidationFailed;
        }
    }

    var errors: u32 = 0;
    const dummy_dep_id: Deployment.Id = .{ .raw = 0 };
    for (config.pipelines) |*pipeline| {
        var spec = Task.resolve(
            alloc,
            io,
            term,
            &config,
            pipeline,
            dummy_dep_id,
            project.dir,
            env_name,
            inst.env,
            "",
        ) catch |err| {
            errors += 1;
            term.err("pipeline '{s}': validation failed: {s}", .{ pipeline.name, @errorName(err) });
            continue;
        };
        spec.deinit(alloc);
    }

    if (errors > 0)
        return error.ValidationFailed;

    term.success("Validation passed: project is ready for deployment", .{});
}
