const std = @import("std");
const builtin = @import("builtin");

pub const current = struct {
    pub const arch = switch (builtin.target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        .arm => "armv7l",
        .x86 => "i686",
        else => @tagName(builtin.target.cpu.arch),
    };
    pub const os = switch (builtin.target.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "windows",
        else => @tagName(builtin.target.os.tag),
    };
    pub const system: []const u8 = arch ++ "-" ++ os;
};

pub const Package = struct {
    name: []const u8,
    summary: ?[]const u8 = null,
    homepage_url: ?[]const u8 = null,
    license: ?[]const u8 = null,
    releases: []const Release = &.{},

    pub const Release = struct {
        version: []const u8,
        last_updated: ?[]const u8 = null,
        platforms_summary: ?[]const u8 = null,
        platforms: []const Platform = &.{},

        pub const Platform = struct {
            arch: ?[]const u8 = null,
            os: ?[]const u8 = null,
            system: []const u8,
            attribute_path: ?[]const u8 = null,
            commit_hash: ?[]const u8 = null,
            date: ?[]const u8 = null,
            outputs: ?[]const Output = null,

            pub const Output = struct {
                name: []const u8,
                path: []const u8,
                default: bool = false,

                pub fn basename(self: Output) []const u8 {
                    return if (std.mem.startsWith(u8, self.path, "/nix/store/"))
                        self.path["/nix/store/".len..]
                    else
                        self.path;
                }
            };

            pub fn default_output(self: Platform) ?Output {
                const outs = self.outputs orelse return null;
                for (outs) |out|
                    if (out.default or std.mem.eql(u8, out.name, "out"))
                        return out;
                return if (outs.len > 0) outs[0] else null;
            }
        };

        pub fn find_platform(self: Release, system: []const u8) ?Platform {
            for (self.platforms) |p|
                if (std.mem.eql(u8, p.system, system))
                    return p;
            return null;
        }

        pub fn store_path(self: Release, system: []const u8) ?[]const u8 {
            const plat = self.find_platform(system) orelse return null;
            const out = plat.default_output() orelse return null;
            return out.path;
        }
    };

    pub fn latest_release(self: Package) ?Release {
        return if (self.releases.len > 0)
            self.releases[0]
        else
            null;
    }

    pub fn find_release(self: Package, version: []const u8) ?Release {
        return for (self.releases) |rel| {
            if (std.mem.eql(u8, rel.version, version))
                break rel;
        } else null;
    }

    pub fn store_path(self: Package, maybe_version: ?[]const u8, system: []const u8) ?[]const u8 {
        const rel = if (maybe_version) |ver|
            self.find_release(ver) orelse return null
        else
            self.latest_release() orelse return null;
        return rel.store_path(system);
    }
};

pub fn query_package(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    name: []const u8,
) !std.json.Parsed(Package) {
    const url = try std.fmt.allocPrint(
        gpa,
        "https://search.devbox.sh/v2/pkg?name={s}",
        .{name},
    );
    defer gpa.free(url);

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/json" },
        },
        .response_writer = &allocating.writer,
    });

    switch (res.status) {
        .ok => {},
        .not_found => return error.PackageNotFound,
        else => return error.InvalidHttpResponse,
    }

    return try std.json.parseFromSlice(Package, gpa, allocating.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
pub const SearchResponse = struct {
    query: []const u8,
    total_results: usize = 0,
    results: []const Item = &.{},

    pub const Item = struct {
        name: []const u8,
        summary: ?[]const u8 = null,
        last_updated: ?[]const u8 = null,
    };
};

pub fn search(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    query_str: []const u8,
    options: struct {},
) !std.json.Parsed(SearchResponse) {
    _ = options;
    const url = try std.fmt.allocPrint(
        gpa,
        "https://search.devbox.sh/v2/search?q={s}",
        .{query_str},
    );
    defer gpa.free(url);

    var allocating: std.Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/json" },
        },
        .response_writer = &allocating.writer,
    });

    switch (res.status) {
        .ok => {},
        .not_found => return error.SearchFailed,
        else => return error.InvalidHttpResponse,
    }

    return try std.json.parseFromSlice(SearchResponse, gpa, allocating.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
