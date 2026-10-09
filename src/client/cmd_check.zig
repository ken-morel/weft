const std = @import("std");
const log = std.log.scoped;

const Task = @import("../daemon/Task.zig");
const Weft = @import("../domain/Weft.zig");
const ClientInstall = @import("ClientInstall.zig");
const Deployment = @import("Deployment.zig");
const Project = @import("Project.zig");

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
        else for (config.pipelines) |other|
            if (other.produces(input))
                if (check_cycle(alloc, config, other, stack))
                    return true;

    return false;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    project: Project,
) !void {
    const l = log(.check);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = project.get_config_leaky(alloc, io) catch |err| {
        l.err("failed to parse weft/weft.zon: {s}", .{@errorName(err)});
        return error.InvalidConfig;
    };

    const sources = config.get_sources();
    for (sources) |src_entry|
        project.dir.access(io, src_entry.@"1", .{}) catch |err|
            l.err("source '{s}' at '{s}': {any}", .{ src_entry.@"0", src_entry.@"1", err });

    for (config.pipelines, 0..) |p1, idx|
        for (config.pipelines[idx + 1 ..]) |p2|
            if (std.mem.eql(u8, p1.name, p2.name))
                l.err("duplicate pipeline name found: '{s}'", .{p1.name});

    var cycle_stack: std.ArrayList([]const u8) = .empty;
    defer cycle_stack.deinit(alloc);

    for (config.pipelines) |pipeline| {
        for (pipeline.in) |input| {
            if (Weft.is_source_artifact(input)) {
                if (std.mem.startsWith(u8, input, "src.")) {
                    const req_src = input["src.".len..];
                    for (sources) |src_entry| {
                        if (std.mem.eql(u8, src_entry.@"0", req_src))
                            break;
                    } else l.err("pipeline '{s}': input '{s}' references source '{s}' not defined in .sources", .{
                        pipeline.name,
                        input,
                        req_src,
                    });
                }
            } else {
                for (config.pipelines) |*other| {
                    if (other.produces(input))
                        break;
                } else l.err("pipeline '{s}': input '{s}' is not produced by any pipeline", .{
                    pipeline.name,
                    input,
                });
            }
        }

        cycle_stack.clearRetainingCapacity();
        if (check_cycle(alloc, config, pipeline, &cycle_stack))
            l.err("pipeline '{s}': cyclic dependency detected", .{pipeline.name});

        if (pipeline.on) |on_list| {
            for (on_list) |target| {
                const found = for (config.remotes) |r| {
                    if (Weft.remote_matches(r, target))
                        break true;
                } else if (std.mem.eql(u8, target, "local") or Weft.remote_has_group(Weft.remote_local, target))
                    true
                else
                    false;

                if (!found)
                    l.err("pipeline '{s}': .on target '{s}' does not match any remote name or group", .{ pipeline.name, target });
            }
        }
    }

    for (config.pipelines) |*pipeline|
        if (pipeline.run) |p_run|
            switch (p_run) {
                .script => |lines| {
                    if (lines.len == 0)
                        l.err("pipeline '{s}': .run.script cannot be empty", .{pipeline.name})
                    else if (!std.mem.startsWith(u8, lines[0], "#!"))
                        l.err("pipeline '{s}': first line of .run.script must be a '#!' shebang", .{pipeline.name});
                },
                .nothing => {},
                .file => |custom| {
                    if (try project.locate_script(alloc, io, custom)) |sp| {
                        defer alloc.free(sp);
                        var file = std.Io.Dir.openFileAbsolute(io, sp, .{}) catch |err| {
                            l.err("pipeline '{s}': failed to open script at '{s}': {s}", .{ pipeline.name, sp, @errorName(err) });
                            continue;
                        };
                        defer file.close(io);

                        var header: [2]u8 = undefined;
                        _ = file.readPositionalAll(io, &header, 0) catch 0;
                        if (!std.mem.eql(u8, &header, "#!"))
                            l.warn("pipeline '{s}': script '{s}' does not have a #! shebang", .{ pipeline.name, sp });
                    } else l.err("custom script '{s}' not found in weft/ for pipeline '{s}'", .{ custom, pipeline.name });
                },
            }
        else {
            if (try project.locate_script(alloc, io, pipeline.name)) |sp| {
                defer alloc.free(sp);
                var file = std.Io.Dir.openFileAbsolute(io, sp, .{}) catch |err| {
                    l.err("pipeline '{s}': failed to open script at '{s}': {s}", .{ pipeline.name, sp, @errorName(err) });
                    continue;
                };
                defer file.close(io);

                var header: [2]u8 = undefined;
                _ = file.readPositionalAll(io, &header, 0) catch 0;
                if (!std.mem.eql(u8, &header, "#!"))
                    l.warn("pipeline '{s}': script '{s}' does not have a #! shebang", .{ pipeline.name, sp });
            } else l.err("no script found in weft/ matching pipeline '{s}' or '{s}.*'", .{ pipeline.name, pipeline.name });
        };

    for (config.modes) |mode| {
        for (config.pipelines) |*pipeline| {
            //TODO: Simplify
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
}
