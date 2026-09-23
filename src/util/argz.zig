const std = @import("std");

/// TODO: Improve error reporting. With diagnostics and help
pub const ArgzParseError = error{
    ExpectedCommand,
    InvalidCommand,
    InvalidArgument,
    UnexpectedArgument,
    ExpectedArgument,
    InvalidFlag,
    InvalidToggleFlag,
    DuplicatePositional,
};

fn flag_matches(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const norm_a = if (ca == '-') '_' else ca;
        const norm_b = if (cb == '-') '_' else cb;
        if (norm_a != norm_b) return false;
    }
    return true;
}

pub const Args = struct {
    const Arg = union(enum) {
        value: []const u8,
        key_value: struct { []const u8, []const u8 },
        toggle: struct { []const u8, bool },
    };
    args: []?Arg,
    pub fn tokenize(alloc: std.mem.Allocator, args: []const []const u8) !@This() {
        const self_args = try alloc.alloc(?Arg, args.len);
        @memset(self_args, null);
        errdefer alloc.free(self_args);
        var skip = false;
        for (args, 0..) |raw, i| {
            if (skip) {
                skip = false;
                continue;
            }
            if (is_flag(raw)) {
                if (is_neg_flag(raw) or i + 1 >= args.len or is_flag(args[i + 1])) {
                    self_args[i] = .{ .toggle = .{ flag_name(raw), !is_neg_flag(raw) } };
                } else if (i + 1 <= args.len) {
                    self_args[i] = .{
                        .key_value = .{ flag_name(args[i]), args[i + 1] },
                    };
                    skip = true;
                } else return ArgzParseError.ExpectedArgument;
            } else {
                self_args[i] = .{ .value = raw };
            }
        }
        return .{
            .args = self_args,
        };
    }
    pub fn take_positional(self: *@This()) ?[]const u8 {
        return for (self.args) |*arg| {
            if (arg.*) |val|
                switch (val) {
                    .value => |s| {
                        arg.* = null;
                        break s;
                    },
                    else => continue,
                };
        } else null;
    }
    pub fn take_flag(self: *@This(), key: []const u8) ?[]const u8 {
        return for (self.args) |*arg| {
            if (arg.*) |a|
                switch (a) {
                    .key_value => |kv| if (flag_matches(kv.@"0", key)) {
                        arg.* = null;
                        break kv.@"1";
                    },
                    .toggle => |kv| if (flag_matches(kv.@"0", key)) {
                        arg.* = null;
                        break if (kv.@"1")
                            "true"
                        else
                            "false";
                    },
                    else => continue,
                };
        } else null;
    }

    pub fn deinit(self: @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.args);
    }
    fn is_flag(str: []const u8) bool {
        if (str.len == 0 or str[0] != '-')
            return false;
        const name = std.mem.trimStart(u8, str, "-");
        return name.len > 0 and std.ascii.isAlphabetic(name[0]);
    }
    fn is_neg_flag(str: []const u8) bool {
        return is_flag(str) and std.mem.startsWith(
            u8,
            std.mem.trimStart(u8, str, "-"),
            "no-",
        );
    }
    fn flag_name(str: []const u8) []const u8 {
        const name = std.mem.trimStart(u8, str, "-");
        return if (is_neg_flag(str))
            name[3..]
        else if (is_flag(str))
            name
        else
            unreachable;
    }
};

pub inline fn parse(comptime A: type, alloc: std.mem.Allocator, io: ?std.Io, args: []const []const u8) anyerror!A {
    return switch (@typeInfo(A)) {
        inline .@"union" => try subcmd(A, alloc, io, args),
        else => try cmdargs(A, alloc, io, args),
    };
}

fn subcmd(comptime C: type, alloc: std.mem.Allocator, io: ?std.Io, args: []const []const u8) anyerror!C {
    if (args.len < 1)
        return ArgzParseError.ExpectedCommand;
    const a = @typeInfo(C);
    return switch (a) {
        inline .@"union" => |U| inline for (U.fields) |field| {
            if (flag_matches(field.name, args[0]))
                break @unionInit(
                    C,
                    field.name,
                    try parse(field.type, alloc, io, args[1..]),
                );
        } else if (@hasField(C, "else"))
            @unionInit(
                C,
                "else",
                try parse(@FieldType(C, "else"), alloc, io, args),
            )
        else
            return error.InvalidCommand,
        inline else => @compileError("unreachable"),
    };
}

fn cmdargs(comptime A: type, alloc: std.mem.Allocator, io: ?std.Io, raw_args: []const []const u8) !A {
    const S = switch (@typeInfo(A)) {
        inline .@"struct" => |S| S,
        inline .void => return {},
        inline else => @compileError("Only structs (and void) are accepted for commands. You may want to wrap " ++ @typeName(A) ++ " in a struct"),
    };

    var args: Args = try .tokenize(alloc, raw_args);
    defer args.deinit(alloc);

    var obj: A = undefined;

    fields: inline for (S.fields) |field|
        @field(obj, field.name) = value: {
            // three cases. Scalar, array, slice.
            // flags take precedence, then positional args
            switch (@typeInfo(field.type)) {
                inline .array => |Ar| {
                    var arr: field.type = undefined;
                    if (Ar.len == 0)
                        continue :fields;
                    var idx: usize = 0;
                    while (args.take_flag(field.name) orelse args.take_positional()) |val| {
                        arr[idx] = try parse_value(Ar.child, alloc, io, val);
                        idx += 1;
                        if (idx >= Ar.len)
                            break :value arr;
                    } else return ArgzParseError.ExpectedArgument;
                },
                inline .pointer => |Ptr| switch (Ptr.size) {
                    .slice => {
                        if (Ptr.child == u8) {
                            break :value if (args.take_flag(field.name) orelse args.take_positional()) |val|
                                val
                            else
                                field.defaultValue() orelse
                                    return ArgzParseError.ExpectedArgument;
                        }
                        var list: std.ArrayList(Ptr.child) = .empty;
                        defer list.deinit(alloc);
                        while (args.take_flag(field.name) orelse args.take_positional()) |val| {
                            try list.append(
                                alloc,
                                try parse_value(Ptr.child, alloc, io, val),
                            );
                        }
                        break :value try list.toOwnedSlice(alloc);
                    },
                    else => @compileError("Argz only supports slice pointers"),
                },
                else => {
                    break :value if (args.take_flag(field.name) orelse args.take_positional()) |val|
                        try parse_value(
                            field.type,
                            alloc,
                            io,
                            val,
                        )
                    else
                        field.defaultValue() orelse
                            return ArgzParseError.ExpectedArgument;
                },
            }
        };
    return obj;
}

pub fn parse_value(comptime T: type, alloc: std.mem.Allocator, io: ?std.Io, val: []const u8) anyerror!T {
    const a = @typeInfo(T);

    if (T == []const u8)
        return val;

    switch (a) {
        inline .@"struct", .@"enum", .@"union", .@"opaque" => if (@hasDecl(T, "argz_parse")) {
            const func = @as(
                fn (std.mem.Allocator, ?std.Io, []const u8) anyerror!T,
                @field(T, "argz_parse"),
            );
            return try func(alloc, io, val);
        },
        else => {},
    }

    return a: switch (a) {
        inline .optional => |Opt| return try parse_value(Opt.child, alloc, io, val),
        inline .bool => if (std.mem.eql(u8, val, "true"))
            true
        else if (std.mem.eql(u8, val, "false"))
            false
        else
            ArgzParseError.InvalidArgument,
        inline .int => std.fmt.parseInt(T, val, 10) catch
            ArgzParseError.InvalidArgument,
        inline .float => std.fmt.parseFloat(T, val) catch
            ArgzParseError.InvalidArgument,
        inline .@"enum" => |E| inline for (E.fields) |field|
            if (flag_matches(field.name, val))
                break :a @enumFromInt(field.value)
            else {}
        else
            ArgzParseError.InvalidArgument,
        inline .@"union" => |U| inline for (U.fields) |field| {
            if (std.mem.startsWith(u8, val, field.name ++ ":"))
                break @unionInit(
                    T,
                    field.name,
                    try parse_value(field.type, alloc, io, val[field.name.len + 1 ..]),
                );
        } else ArgzParseError.InvalidArgument,
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    };
}

pub const SocketAddr = struct {
    host: []const u8,
    port: ?u16 = null,

    pub fn argz_parse(_: std.mem.Allocator, _: ?std.Io, str: []const u8) anyerror!@This() {
        if (str.len > 0 and str[0] == '[') {
            if (std.mem.indexOfScalar(u8, str, ']')) |close_bracket| {
                const host = str[1..close_bracket];
                if (close_bracket + 1 < str.len and str[close_bracket + 1] == ':') {
                    const port = try std.fmt.parseInt(u16, str[close_bracket + 2 ..], 10);
                    return .{ .host = host, .port = port };
                }
                return .{ .host = host, .port = null };
            }
        }
        if (std.mem.lastIndexOfScalar(u8, str, ':')) |colon| {
            if (std.mem.indexOfScalar(u8, str[0..colon], ':') == null) {
                const port_str = str[colon + 1 ..];
                if (std.fmt.parseInt(u16, port_str, 10)) |port| {
                    return .{
                        .host = str[0..colon],
                        .port = port,
                    };
                } else |_| {}
            }
        }
        return .{
            .host = str,
            .port = null,
        };
    }
};

pub const ExistingPath = struct {
    value: []const u8,
    pub fn argz_parse(_: std.mem.Allocator, io: ?std.Io, str: []const u8) anyerror!@This() {
        if (io) |i| {
            std.Io.Dir.cwd().access(i, str, .{}) catch return error.FileNotFound;
        }
        return .{
            .value = str,
        };
    }
};

pub fn doc(comptime name: []const u8, comptime T: type) []const u8 {
    @setEvalBranchQuota(100_000);
    return comptime switch (@typeInfo(T)) {
        .@"union" => |U| blk: {
            var out: []const u8 = "";

            if (docstring(T)) |description|
                out = out ++ description ++ "\n\n";

            out = out ++ "Usage:\n  " ++ name ++ " <command> [args]\n";

            if (@hasField(T, "else"))
                out = out ++ "\n" ++ arguments(@FieldType(T, "else"));

            out = out ++ "\nCommands:\n";

            for (U.fields) |field| {
                if (std.mem.eql(u8, field.name, "else"))
                    continue;

                out = out ++ "\n";
                out = out ++ prefix_lines(
                    command_doc(T, field.name, field.type),
                    "  ",
                );
            }

            break :blk out;
        },

        .@"struct" => blk: {
            if (@hasDecl(T, "argz_parse"))
                break :blk "";

            var out: []const u8 = "";

            if (docstring(T)) |description|
                out = out ++ description ++ "\n\n";

            const args_doc = arguments(T);
            if (args_doc.len > 0) {
                out = out ++ "Usage:\n  " ++ name ++ " [args]\n\n" ++ args_doc;
            } else {
                out = out ++ "Usage:\n  " ++ name ++ " [args]\n";
            }

            break :blk out;
        },
        .void => "",
        else => @compileError(
            "cannot document " ++ @typeName(T) ++
                "; expected a union, struct, or void",
        ),
    };
}

fn command_doc(
    comptime Parent: type,
    comptime name: []const u8,
    comptime T: type,
) []const u8 {
    comptime var out: []const u8 = name;

    if (docstring_arg(Parent, name)) |description|
        out = out ++ "  " ++ description;

    if (@typeInfo(T) != .void)
        out = out ++ "\n" ++ doc(name, T);

    return out ++ "\n";
}

fn arguments(comptime T: type) []const u8 {
    const S = switch (@typeInfo(T)) {
        .@"struct" => |S| S,
        else => @compileError(
            "argument container must be a struct, found " ++
                @typeName(T),
        ),
    };

    if (S.fields.len == 0)
        return "";

    var out: []const u8 = "Arguments:\n";

    for (S.fields) |field| {
        out = out ++ "  ";
        out = out ++ field.name;
        out = out ++ " ";
        out = out ++ type_name(field.type);

        if (field.defaultValue() != null)
            out = out ++ " [default]";

        if (docstring_arg(T, field.name)) |description| {
            out = out ++ "\n";
            out = out ++ prefix_lines(description, "    ");
        }

        out = out ++ "\n";
    }

    return out;
}

fn prefix_lines(
    comptime text: []const u8,
    comptime prefix: []const u8,
) []const u8 {
    if (text.len == 0)
        return "";

    var out: []const u8 = "";
    var start: usize = 0;

    while (start < text.len) {
        const remaining = text[start..];
        const newline = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;

        out = out ++ prefix ++ remaining[0..newline];

        if (newline == remaining.len)
            break;

        out = out ++ "\n";
        start += newline + 1;
    }

    return out;
}

pub fn docstring(comptime T: type) ?[]const u8 {
    return comptime switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => if (@hasDecl(T, "doc"))
            @field(T, "doc")
        else
            null,
        else => null,
    };
}

pub fn docstring_arg(
    comptime T: type,
    comptime name: []const u8,
) ?[]const u8 {
    return comptime switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => if (@hasDecl(T, "doc_" ++ name))
            @field(T, "doc_" ++ name)
        else
            null,
        else => null,
    };
}

fn type_name(comptime T: type) []const u8 {
    return comptime switch (@typeInfo(T)) {
        .pointer => |P| switch (P.size) {
            .slice => "[]" ++ type_name(P.child),
            else => "*" ++ type_name(P.child),
        },
        .array => |A| std.fmt.comptimePrint("[{}]{s}", .{
            A.len,
            type_name(A.child),
        }),
        .optional => |O| "?" ++ type_name(O.child),
        else => @typeName(T),
    };
}

test "argz tokenize and parse scalar flags and positionals" {
    const alloc = std.testing.allocator;

    const TestCmd = struct {
        name: []const u8,
        count: u32 = 1,
        verbose: bool = false,
        user: ?[]const u8 = null,
    };

    const parsed1 = try parse(TestCmd, alloc, null, &.{ "hello", "--count", "42", "--verbose", "--user", "admin" });
    try std.testing.expectEqualStrings("hello", parsed1.name);
    try std.testing.expectEqual(@as(u32, 42), parsed1.count);
    try std.testing.expectEqual(true, parsed1.verbose);
    try std.testing.expectEqualStrings("admin", parsed1.user.?);

    const parsed2 = try parse(TestCmd, alloc, null, &.{"world"});
    try std.testing.expectEqualStrings("world", parsed2.name);
    try std.testing.expectEqual(@as(u32, 1), parsed2.count);
    try std.testing.expectEqual(false, parsed2.verbose);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed2.user);
}

test "argz parse subcommands union" {
    const alloc = std.testing.allocator;

    const SubA = struct {
        val: []const u8,
    };
    const SubB = struct {
        items: [][]const u8 = &.{},
    };
    const Root = union(enum) {
        a: SubA,
        b: SubB,
        run: struct {},
    };

    const res_a = try parse(Root, alloc, null, &.{ "a", "foo" });
    switch (res_a) {
        .a => |a| try std.testing.expectEqualStrings("foo", a.val),
        else => unreachable,
    }

    const res_b = try parse(Root, alloc, null, &.{ "b", "x", "y", "z" });
    switch (res_b) {
        .b => |b| {
            try std.testing.expectEqual(@as(usize, 3), b.items.len);
            try std.testing.expectEqualStrings("x", b.items[0]);
            try std.testing.expectEqualStrings("y", b.items[1]);
            try std.testing.expectEqualStrings("z", b.items[2]);
            alloc.free(b.items);
        },
        else => unreachable,
    }

    const res_run = try parse(Root, alloc, null, &.{"run"});
    switch (res_run) {
        .run => {},
        else => unreachable,
    }
}

test "argz SocketAddr parsing" {
    const s1 = try SocketAddr.argz_parse(std.testing.allocator, null, "192.168.1.1:9338");
    try std.testing.expectEqualStrings("192.168.1.1", s1.host);
    try std.testing.expectEqual(@as(?u16, 9338), s1.port);

    const s2 = try SocketAddr.argz_parse(std.testing.allocator, null, "example.com");
    try std.testing.expectEqualStrings("example.com", s2.host);
    try std.testing.expectEqual(@as(?u16, null), s2.port);

    const s3 = try SocketAddr.argz_parse(std.testing.allocator, null, "[::1]:8080");
    try std.testing.expectEqualStrings("::1", s3.host);
    try std.testing.expectEqual(@as(?u16, 8080), s3.port);
}

test "argz doc generation" {
    const App = union(enum) {
        const doc = "Test App";
        cmd: struct {
            const doc = "Run cmd";
            const doc_flag = "A flag description";
            flag: ?[]const u8 = null,
        },
    };
    const documentation = doc("testapp", App);
    try std.testing.expect(documentation.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, documentation, "Test App") != null);
    try std.testing.expect(std.mem.indexOf(u8, documentation, "cmd") != null);
}
