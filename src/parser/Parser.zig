const std = @import("std");
const Config = @import("../config/Weft.zig");
const NumPattern = @import("numpattern.zig").NumPattern;

alloc: std.mem.Allocator,
line_iter: std.mem.SplitIterator(u8, .scalar),
line: ?[]const u8,
idx: usize = 0,
ln: usize = 0,
conf: Config = Config{},
in_workspace: bool = false,

pub fn create(alloc: std.mem.Allocator, txt: []const u8) ?@This() {
    var iter = std.mem.splitScalar(u8, txt, '\n');
    const ln = iter.next();
    return .{
        .alloc = alloc,
        .line_iter = iter,
        .line = ln,
    };
}

pub fn parse(self: *@This()) !void {
    while (true) {
        self.parse_statement() catch |err| {
            if (err == error.Eof)
                break
            else {
                return err;
            }
        } orelse break;
    }
}

pub fn next_line(self: *@This()) void {
    self.line = self.line_iter.next();
    self.idx = 0;
    self.ln += 1;
}
pub fn ch(self: @This()) ?u8 {
    return if (self.line) |ln|
        if (self.idx < ln.len)
            ln[self.idx]
        else
            null
    else
        null;
}

pub fn skip_empty_lines(self: *@This()) void {
    while (self.line) |ln| {
        if (!std.mem.allEqual(u8, ln, ' '))
            break;
        self.next_line();
    }
}
pub fn skip_indent(self: *@This()) void {
    if (self.line) |ln| {
        while (ln.len > self.idx and ln[self.idx] == ' ')
            self.idx += 1;
    }
}

pub fn is_name_char(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

pub fn parse_name(self: *@This()) ?[]const u8 {
    const start = self.idx;
    const ln = self.line orelse return null;
    while (self.idx < ln.len and @This().is_name_char(ln[self.idx]))
        self.idx += 1;
    return if (self.idx == start)
        null
    else
        ln[start..self.idx];
}

pub fn skip_space(self: *@This()) !void {
    if (self.line) |ln| {
        if (self.idx < ln.len) {
            if (ln[self.idx] == ' ') {
                return;
            }
        }
    }
    return error.SpaceExpected;
}
pub fn skip_spaces(self: *@This()) ?usize {
    const start = self.idx;
    if (self.line) |ln| {
        while (self.idx < ln.len and ln[self.idx] == ' ')
            self.idx += 1;
    }
    const len = self.idx - start;
    return if (len > 0)
        len
    else
        null;
}

pub fn parse_statement(self: *@This()) !?void {
    self.skip_empty_lines();
    self.idx = 0;
    while (self.line) |_| {
        self.skip_indent();
        const indent = self.idx;
        if (self.ch()) |c| {
            if (indent > 0)
                return error.UnexpectedIndent;
            switch (c) {
                ':' => { // we parse a new key-value block
                    self.idx += 1;
                    const key = self.parse_name() orelse return error.NameExpected;
                    if (std.mem.eql(u8, key, "name")) {
                        _ = self.skip_spaces();
                        self.conf.name = self.parse_name() orelse return error.NameExpected;
                        try self.line_ends();
                        return;
                    } else if (std.mem.eql(u8, key, "volumes")) {
                        try self.line_ends();
                        return if (self.conf.volumes) |_|
                            error.DuplicateKey
                        else
                            try self.parse_service_volumes();
                    } else if (std.mem.eql(u8, key, "ports")) {
                        try self.line_ends();
                        return if (self.conf.ports) |_|
                            error.DuplicateKey
                        else
                            try self.parse_service_ports();
                    } else if (std.mem.eql(u8, key, "databases")) {
                        try self.line_ends();
                        return if (self.conf.databases) |_|
                            error.DuplicateKey
                        else
                            try self.parse_service_databases();
                    } else {
                        return error.InvalidToken;
                    }
                },
                '.' => { // we parse a pipeline
                    const pipe = try self.parse_pipeline();
                    if (self.conf.pipelines) |old| {
                        const new = try self.alloc.realloc(old, old.len + 1);
                        new[old.len] = pipe;
                        self.conf.pipelines = new;
                    } else {
                        self.conf.pipelines = try self.alloc.dupe(@TypeOf(pipe), &.{pipe});
                    }
                },
                '#' => {
                    self.next_line();
                    continue;
                },
                '[' => {
                    self.idx += 1;
                    if (!std.mem.eql(u8, "[workspace]", self.line))
                        return error.UnexpectedToken;
                    if (self.conf.workspace) |_|
                        return error.DuplicateKey;

                    self.in_workspace = true;
                    self.next_line();
                },
                else => {
                    return error.UnexpectedToken;
                },
            }
        } else self.next_line();
    }
    return null;
}
pub fn parse_pipeline(self: *@This()) !Config.Pipeline {
    self.idx += 1;
    const pipeline_name = self.parse_name() orelse return error.NameExpected;

    var inputs: std.ArrayList(Config.Pipeline.Input) = .empty;
    defer inputs.deinit(self.alloc);

    var runtimes: std.ArrayList([]const u8) = .empty;
    defer runtimes.deinit(self.alloc);
    var volumes: std.ArrayList([]const u8) = .empty;
    defer volumes.deinit(self.alloc);
    var databases: std.ArrayList([]const u8) = .empty;
    defer databases.deinit(self.alloc);
    var keep: std.ArrayList([]const u8) = .empty;
    defer keep.deinit(self.alloc);

    var script: ?Config.Pipeline.Script = null;

    self.idx += 1;

    var second_instance: ?Config.Pipeline.SecondInstance = null;

    // check if the pipeline has attributes( -wait(10), -ignore, ... )
    _ = self.skip_spaces();
    if (self.ch()) |c| {
        if (c == '-') {
            self.idx += 1;
            const pipeline_attr_name = self.parse_name() orelse return error.NameExpected;
            if (try self.take_in_brackets('(', ')')) |num| {
                const secs = try std.fmt.parseInt(u32, num, 10);
                second_instance = if (std.mem.eql(u8, pipeline_attr_name, "wait"))
                    .{ .wait = secs }
                else if (std.mem.eql(u8, pipeline_attr_name, "safe"))
                    .{ .safe = secs }
                else
                    return error.UnexpectedNumber;
            } else {
                second_instance = if (std.mem.eql(u8, pipeline_attr_name, "wait"))
                    .{ .wait = null }
                else if (std.mem.eql(u8, pipeline_attr_name, "safe"))
                    return error.ExpectedNumber
                else if (std.mem.eql(u8, pipeline_attr_name, "kill"))
                    .{ .kill = {} }
                else if (std.mem.eql(u8, pipeline_attr_name, "ignore"))
                    .{ .ignore = {} }
                else
                    return error.InvalidToken;
            }
        }
    }
    self.next_line();
    self.skip_empty_lines();
    // parse the pipeline contents
    while (self.line) |pline| : (self.skip_empty_lines()) {
        self.skip_indent();
        const pindent = self.idx;
        if (pindent == 0)
            break
        else if (pindent != 2)
            return error.UnexpectedIndent;

        if (self.idx >= pline.len) {
            self.next_line();
            continue;
        }
        if (self.ch()) |pc| {
            switch (pc) {
                '<' => { // we parse a pipeline input argument
                    self.idx += 1;
                    _ = self.skip_spaces();
                    // & means for reference argument, do not consume
                    const consume = if (self.idx < pline.len and pline[self.idx] == '&') blk: {
                        self.idx += 1;
                        _ = self.skip_spaces();
                        break :blk false;
                    } else true;
                    var namespace: ?[]const u8 = null;
                    var name = self.parse_name() orelse return error.NameExpected;
                    // we have namespace.name
                    if (self.idx < pline.len and pline[self.idx] == '.') {
                        self.idx += 1;
                        namespace = name;
                        name = self.parse_name() orelse return error.NameExpected;
                    } else {}
                    _ = self.skip_spaces();
                    const exit_pattern = if (self.idx < pline.len and NumPattern(u8).is_start(pline[self.idx])) blk: {
                        const start = self.idx;
                        _ = self.take_till(' ');
                        const end = self.idx;
                        const pattern = try NumPattern(u8).parse(self.alloc, pline[start..end]);
                        break :blk pattern;
                    } else null;
                    try inputs.append(self.alloc, .{
                        .namespace = namespace,
                        .name = name,
                        .consume = consume,
                        .code = exit_pattern,
                        .same_remote = false,
                    });
                    self.next_line();
                },
                '~' => { // preserve path pattern
                    self.idx += 1;
                    _ = self.skip_spaces();
                    const start = self.idx;
                    if (start < pline.len) {
                        const path = pline[start..];

                        //TODO: verify the path somehow
                        try keep.append(self.alloc, path);
                        self.next_line();
                    } else return error.ExpectedToken;
                },
                '!' => { // script
                    self.idx += 1;
                    script = try self.parse_script();
                },
                else => {
                    self.next_line();
                },
            }
        } else self.next_line();
    }
    return .{
        .name = pipeline_name,
        .databases = try databases.toOwnedSlice(self.alloc),
        .volumes = try volumes.toOwnedSlice(self.alloc),
        .runtimes = try runtimes.toOwnedSlice(self.alloc),
        .inputs = try inputs.toOwnedSlice(self.alloc),
        .keep = &.{},
        .second_instance = second_instance,
        .script = script,
    };
}

pub fn parse_script(self: *@This()) !Config.Pipeline.Script {
    const lang = self.parse_name() orelse return error.NameExpected;
    self.next_line();

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(self.alloc);

    var indent: ?usize = null;

    while (self.line) |line| : (self.next_line()) {
        self.skip_indent();
        const local_ind = self.idx;
        if (indent) |ind| {
            if (local_ind < ind)
                break;
        } else indent = local_ind;
        if (local_ind < line.len + 1)
            try lines.append(self.alloc, line[local_ind..]);
    }
    return .{
        .lang = lang,
        .lines = try lines.toOwnedSlice(self.alloc),
    };
}

pub fn take_in_brackets(self: *@This(), open: u8, close: u8) !?[]const u8 {
    const line = self.line.?;
    if (self.idx >= line.len)
        return null;
    if (line[self.idx] != open)
        return null;
    self.idx += 1;
    return self.take_till(close) orelse error.UnclosedBrace;
}
pub fn take_till(self: *@This(), end: u8) ?[]const u8 {
    if (self.line) |line| {
        const start = self.idx;
        while (self.idx < line.len and line[self.idx] != end)
            self.idx += 1;
        const stop = self.idx;
        if (stop >= line.len)
            return null
        else {
            self.idx += 1;
            return line[start..stop];
        }
    } else return null;
}

pub fn line_ends(self: *@This()) !void {
    self.next_line();
}
pub fn parse_env_bind(self: *@This()) !?struct { []const u8, []const u8 } {
    self.skip_empty_lines();
    if (self.line) |_| {
        self.skip_indent();
        const indent = self.idx;
        if (indent == 0)
            return null
        else if (indent != 2)
            return error.ExpectedSingleIndent;
        if (self.ch()) |c| {
            if (c == ':') {
                self.idx += 1;
                const key = self.parse_name() orelse return error.ExpectedName;
                _ = self.skip_spaces();
                const env = self.parse_name() orelse return error.ExpectedName;
                try self.line_ends();
                return .{ key, env };
            } else return error.ExpectedKey;
        } else {
            return error.ExpectedChar;
        }
    } else return null;
}
pub fn parse_service_volumes(self: *@This()) !void {
    var items: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    defer items.deinit(self.alloc);
    while (try self.parse_env_bind()) |bind|
        try items.append(self.alloc, bind);

    self.conf.volumes = try items.toOwnedSlice(self.alloc);
}

pub fn parse_service_databases(self: *@This()) !void {
    var items: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    defer items.deinit(self.alloc);
    while (try self.parse_env_bind()) |bind|
        try items.append(self.alloc, bind);

    self.conf.databases = try items.toOwnedSlice(self.alloc);
}

pub fn parse_service_ports(self: *@This()) !void {
    var items: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    defer items.deinit(self.alloc);
    while (try self.parse_env_bind()) |bind|
        try items.append(self.alloc, bind);

    self.conf.ports = try items.toOwnedSlice(self.alloc);
}
pub fn print_trace(self: @This(), io: std.Io) !void {
    var buffer: [4 << 10]u8 = undefined;

    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;

    defer stderr_writer.flush() catch {};

    try stderr.print("\nParsing error encountered at line {}:\n", .{self.ln + 1});

    const current_line = self.line orelse {
        try stderr.writeAll("<End of File or empty line>\n");
        return;
    };

    try stderr.print("{s}\n", .{current_line});

    var i: usize = 0;
    while (i < self.idx) : (i += 1) {
        if (i < current_line.len and current_line[i] == '\t') {
            try stderr.writeByte('\t');
        } else {
            try stderr.writeByte(' ');
        }
    }
    try stderr.writeAll("^\n\n");
}
