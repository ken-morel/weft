const std = @import("std");
const Workspace = @import("Workspace.zig");
const Service = @import("Service.zig");
const NumPattern = @import("numpattern.zig").NumPattern;

alloc: std.mem.Allocator,
line_iter: std.mem.SplitIterator(u8, .scalar),
line: ?[]const u8,
idx: usize = 0,
ln: usize = 0,

pub fn init(alloc: std.mem.Allocator, txt: []const u8) ?@This() {
    var iter = std.mem.splitScalar(u8, txt, '\n');
    const first = iter.next();
    return .{
        .alloc = alloc,
        .line_iter = iter,
        .line = first,
    };
}

pub fn next_line(self: *@This()) void {
    self.line = self.line_iter.next();
    self.idx = 0;
    self.ln += 1;
}

pub fn ch(self: @This()) ?u8 {
    return if (self.line) |ln|
        if (self.idx < ln.len) ln[self.idx] else null
    else
        null;
}

pub fn skip_empty_lines(self: *@This()) void {
    while (self.line) |ln| {
        const trimmed = std.mem.trimStart(u8, ln, " ");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            self.next_line();
        } else {
            break;
        }
    }
}

pub fn skip_indent(self: *@This()) void {
    if (self.line) |ln| {
        while (self.idx < ln.len and ln[self.idx] == ' ')
            self.idx += 1;
    }
}

pub fn skip_space(self: *@This()) !void {
    if (self.line) |ln|
        if (self.idx < ln.len and ln[self.idx] == ' ')
            return;

    return error.SpaceExpected;
}

pub fn skip_spaces(self: *@This()) ?usize {
    const start = self.idx;
    if (self.line) |ln| {
        while (self.idx < ln.len and ln[self.idx] == ' ')
            self.idx += 1;
    }
    const n = self.idx - start;
    return if (n > 0) n else null;
}

pub fn is_name_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn parse_name(self: *@This()) ?[]const u8 {
    const start = self.idx;
    const ln = self.line orelse return null;
    while (self.idx < ln.len and is_name_char(ln[self.idx]))
        self.idx += 1;
    return if (self.idx == start) null else ln[start..self.idx];
}

pub fn is_key_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

pub fn parse_key(self: *@This()) ?[]const u8 {
    const start = self.idx;
    const ln = self.line orelse return null;
    while (self.idx < ln.len and is_key_char(ln[self.idx]))
        self.idx += 1;
    return if (self.idx == start) null else ln[start..self.idx];
}

pub fn take_till(self: *@This(), end: u8) ?[]const u8 {
    if (self.line) |ln| {
        const start = self.idx;
        while (self.idx < ln.len and ln[self.idx] != end)
            self.idx += 1;
        if (self.idx >= ln.len) return null;
        const result = ln[start..self.idx];
        self.idx += 1;
        return result;
    }
    return null;
}

pub fn take_in_brackets(self: *@This(), open: u8, close: u8) !?[]const u8 {
    const ln = self.line orelse return null;
    if (self.idx >= ln.len or ln[self.idx] != open) return null;
    self.idx += 1;
    return self.take_till(close) orelse error.UnclosedBrace;
}

pub fn line_ends(self: *@This()) !void {
    self.next_line();
}

pub fn parse_workspace(self: *@This()) !Workspace {
    var ws: Workspace = .{};
    while (true) {
        self.parse_workspace_statement(&ws) catch |err| {
            if (err == error.Eof) break else return err;
        } orelse break;
    }
    return ws;
}

fn parse_workspace_statement(self: *@This(), ws: *Workspace) !?void {
    self.skip_empty_lines();
    if (self.line == null) return null;

    self.idx = 0;
    self.skip_indent();
    if (self.idx > 0) return error.UnexpectedIndent;

    const c = self.ch() orelse {
        self.next_line();
        return;
    };

    switch (c) {
        ':' => {
            self.idx += 1;
            const key = self.parse_name() orelse return error.NameExpected;

            if (std.mem.eql(u8, key, "name")) {
                _ = self.skip_spaces();
                ws.name = self.parse_name() orelse return error.NameExpected;
                self.next_line();
            } else if (std.mem.eql(u8, key, "volumes")) {
                self.next_line();
                if (ws.volumes != null) return error.DuplicateKey;
                ws.volumes = try self.parse_section_volumes();
            } else if (std.mem.eql(u8, key, "ports")) {
                self.next_line();
                if (ws.ports != null) return error.DuplicateKey;
                ws.ports = try self.parse_section_ports();
            } else if (std.mem.eql(u8, key, "databases")) {
                self.next_line();
                if (ws.databases != null) return error.DuplicateKey;
                ws.databases = try self.parse_section_databases();
            } else if (std.mem.eql(u8, key, "runtimes")) {
                self.next_line();
                if (ws.runtimes != null) return error.DuplicateKey;
                ws.runtimes = try self.parse_section_runtimes();
            } else {
                return error.UnknownDirective;
            }
        },
        '#' => self.next_line(),
        else => return error.UnexpectedToken,
    }
}

pub fn parse_service(self: *@This()) !Service {
    var svc: Service = .{};
    var pipelines: std.ArrayList(Service.Pipeline) = .empty;
    defer pipelines.deinit(self.alloc);
    var required_env: std.ArrayList([]const u8) = .empty;
    defer required_env.deinit(self.alloc);
    var env_bindings: std.ArrayList(struct { []const u8, Service.Pipeline.EnvBinding }) = .empty;
    defer env_bindings.deinit(self.alloc);

    while (true) {
        self.parse_service_statement(&svc, &pipelines, &required_env, &env_bindings) catch |err| {
            if (err == error.Eof) break else return err;
        } orelse break;
    }
    svc.pipelines = try pipelines.toOwnedSlice(self.alloc);
    svc.required_env = try required_env.toOwnedSlice(self.alloc);
    svc.env_bindings = try env_bindings.toOwnedSlice(self.alloc);
    return svc;
}

fn parse_service_statement(
    self: *@This(),
    svc: *Service,
    pipelines: *std.ArrayList(Service.Pipeline),
    required_env: *std.ArrayList([]const u8),
    env_bindings: *std.ArrayList(struct { []const u8, Service.Pipeline.EnvBinding }),
) !?void {
    self.skip_empty_lines();
    if (self.line == null) return null;

    self.idx = 0;
    self.skip_indent();
    if (self.idx > 0) return error.UnexpectedIndent;

    const c = self.ch() orelse {
        self.next_line();
        return;
    };

    switch (c) {
        ':' => {
            self.idx += 1;
            const key = self.parse_name() orelse return error.NameExpected;

            if (std.mem.eql(u8, key, "name")) {
                _ = self.skip_spaces();
                svc.name = self.parse_name() orelse return error.NameExpected;
                self.next_line();
            } else if (std.mem.eql(u8, key, "workspace")) {
                _ = self.skip_spaces();
                svc.workspace = self.parse_name() orelse return error.NameExpected;
                self.next_line();
            } else {
                return error.UnknownDirective;
            }
        },

        '.' => {
            const pipe = try self.parse_pipeline();
            try pipelines.append(self.alloc, pipe);
        },

        '$' => {
            const bind = try self.parse_env_binding_line();
            try env_bindings.append(self.alloc, bind);
        },

        '<' => {
            self.idx += 1;
            _ = self.skip_spaces();
            if (self.ch() != '$') return error.EnvVarExpected;
            self.idx += 1;
            const name = self.parse_name() orelse return error.NameExpected;
            try required_env.append(self.alloc, name);
            self.next_line();
        },

        '#' => self.next_line(),

        else => return error.UnexpectedToken,
    }
}

fn parse_section_item(self: *@This()) !?struct { key: []const u8, rest: []const u8 } {
    self.skip_empty_lines();
    const ln = self.line orelse return null;

    var ind: usize = 0;
    while (ind < ln.len and ln[ind] == ' ') ind += 1;

    if (ind == 0) return null;
    if (ind != 2) return error.UnexpectedIndent;

    self.idx = ind;
    if (self.ch() != ':') return error.ExpectedColon;
    self.idx += 1;

    const key = self.parse_key() orelse return error.KeyExpected;
    _ = self.skip_spaces();

    const rest = if (self.line) |l| l[self.idx..] else "";
    self.next_line();
    return .{ .key = key, .rest = rest };
}

fn parse_size(s: []const u8) !u64 {
    if (s.len == 0) return error.EmptySize;
    const has_unit = std.ascii.isAlphabetic(s[s.len - 1]);
    const num_part = if (has_unit) s[0 .. s.len - 1] else s;
    const unit: u64 = if (has_unit) switch (std.ascii.toLower(s[s.len - 1])) {
        'k' => 1024,
        'm' => 1024 * 1024,
        'g' => 1024 * 1024 * 1024,
        't' => @as(u64, 1024) * 1024 * 1024 * 1024,
        else => return error.UnknownSizeUnit,
    } else 1;
    const num = try std.fmt.parseInt(u64, num_part, 10);
    return num * unit;
}

fn parse_section_volumes(self: *@This()) !Workspace.keyed(Workspace.Volume) {
    var items: std.ArrayList(struct { []const u8, Workspace.Volume }) = .empty;
    defer items.deinit(self.alloc);

    while (try self.parse_section_item()) |item| {
        var ram_fs = false;
        var max_storage: ?u64 = null;

        var toks = std.mem.tokenizeScalar(u8, item.rest, ' ');
        while (toks.next()) |tok| {
            if (std.mem.eql(u8, tok, "ram_fs")) {
                ram_fs = true;
            } else if (std.mem.startsWith(u8, tok, "max(") and tok[tok.len - 1] == ')') {
                max_storage = try parse_size(tok[4 .. tok.len - 1]);
            }
        }

        try items.append(self.alloc, .{ item.key, .{ .ram_fs = ram_fs, .max_storage = max_storage } });
    }

    return try items.toOwnedSlice(self.alloc);
}

fn parse_section_databases(self: *@This()) !Workspace.keyed(Workspace.Database) {
    var items: std.ArrayList(struct { []const u8, Workspace.Database }) = .empty;
    defer items.deinit(self.alloc);

    while (try self.parse_section_item()) |item| {
        const name = std.mem.trim(u8, item.rest, " ");
        const db: Workspace.Database = if (std.mem.eql(u8, name, "postgres"))
            .{ .postgres = {} }
        else if (std.mem.eql(u8, name, "redis"))
            .{ .redis = {} }
        else if (std.mem.eql(u8, name, "sqlite"))
            .{ .sqlite = {} }
        else
            return error.UnknownDatabaseType;
        try items.append(self.alloc, .{ item.key, db });
    }

    return try items.toOwnedSlice(self.alloc);
}

fn parse_section_ports(self: *@This()) !Workspace.keyed(Workspace.Port) {
    var items: std.ArrayList(struct { []const u8, Workspace.Port }) = .empty;
    defer items.deinit(self.alloc);

    while (try self.parse_section_item()) |item| {
        const rest = std.mem.trim(u8, item.rest, " ");
        var port: ?u16 = null;
        var domain: ?[]const u8 = null;

        if (rest.len > 0) {
            var toks = std.mem.tokenizeScalar(u8, rest, ' ');
            const first = toks.next();
            const second = toks.next();

            if (first) |f| {
                if (second) |s| {
                    domain = f;
                    port = try std.fmt.parseInt(u16, s, 10);
                } else {
                    port = std.fmt.parseInt(u16, f, 10) catch null;
                    if (port == null) domain = f;
                }
            }
        }

        try items.append(self.alloc, .{ item.key, .{ .port = port, .domain = domain } });
    }

    return try items.toOwnedSlice(self.alloc);
}

fn parse_section_runtimes(self: *@This()) !Workspace.keyed(Workspace.Runtime) {
    var items: std.ArrayList(struct { []const u8, Workspace.Runtime }) = .empty;
    defer items.deinit(self.alloc);

    while (try self.parse_section_item()) |item| {
        const runtime = try self.parse_runtime_value(item.rest);
        try items.append(self.alloc, .{ item.key, runtime });
    }

    return try items.toOwnedSlice(self.alloc);
}

fn parse_runtime_value(self: *@This(), rest: []const u8) !Workspace.Runtime {
    var entries: std.ArrayList(Workspace.InstallerEntry) = .empty;
    defer entries.deinit(self.alloc);

    var parts = std.mem.splitScalar(u8, rest, ';');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0) continue;
        try entries.append(self.alloc, try parse_installer_spec(self.alloc, trimmed));
    }

    if (entries.items.len == 0) return error.EmptyRuntimeSpec;

    const all = try entries.toOwnedSlice(self.alloc);
    return .{
        .primary = all[0],
        .fallbacks = all[1..],
    };
}

fn parse_installer_spec(alloc: std.mem.Allocator, spec: []const u8) !Workspace.InstallerEntry {
    var i: usize = 0;

    const inst_start = i;
    while (i < spec.len and is_key_char(spec[i])) i += 1;
    if (i == inst_start) return error.InstallerNameExpected;
    const installer = spec[inst_start..i];

    var version: ?[]const u8 = null;
    if (i < spec.len and spec[i] == '@') {
        i += 1;
        const v_start = i;
        while (i < spec.len and spec[i] != ' ') i += 1;
        if (i > v_start) version = spec[v_start..i];
    }

    while (i < spec.len and spec[i] == ' ') i += 1;

    var package: ?[]const u8 = null;
    var features: std.ArrayList([]const u8) = .empty;
    defer features.deinit(alloc);

    if (i < spec.len) {
        const pkg_start = i;
        while (i < spec.len and spec[i] != '@' and spec[i] != ' ' and spec[i] != ',')
            i += 1;

        if (i > pkg_start) {
            package = spec[pkg_start..i];

            if (i < spec.len and spec[i] == '@') {
                i += 1;
                const pv_start = i;
                while (i < spec.len and spec[i] != ' ' and spec[i] != ',') i += 1;
                if (i > pv_start and version == null)
                    version = spec[pv_start..i];
            }

            while (i < spec.len and spec[i] == ' ') i += 1;

            if (i < spec.len) {
                const feat_str = if (spec[i] == ',') spec[i + 1 ..] else spec[i..];
                var feat_iter = std.mem.splitScalar(u8, feat_str, ',');
                while (feat_iter.next()) |f| {
                    const trimmed = std.mem.trim(u8, f, " ");
                    if (trimmed.len > 0) try features.append(alloc, trimmed);
                }
            }
        }
    }

    return .{
        .installer = installer,
        .version = version,
        .package = package,
        .features = try features.toOwnedSlice(alloc),
    };
}

pub fn parse_pipeline(self: *@This()) !Service.Pipeline {
    self.idx += 1;
    const pipeline_name = self.parse_name() orelse return error.NameExpected;

    var second_instance: ?Service.Pipeline.SecondInstance = null;
    _ = self.skip_spaces();
    if (self.ch()) |c| {
        if (std.ascii.isAlphabetic(c)) {
            const attr = self.parse_name() orelse return error.NameExpected;
            if (try self.take_in_brackets('(', ')')) |num_str| {
                const secs = std.fmt.parseInt(u32, num_str, 10) catch return error.InvalidNumber;
                second_instance = if (std.mem.eql(u8, attr, "wait"))
                    .{ .wait = secs }
                else if (std.mem.eql(u8, attr, "safe"))
                    .{ .safe = secs }
                else
                    return error.UnknownPipelineAttr;
            } else {
                second_instance = if (std.mem.eql(u8, attr, "wait"))
                    .{ .wait = null }
                else if (std.mem.eql(u8, attr, "safe"))
                    return error.SafeRequiresNumber
                else if (std.mem.eql(u8, attr, "kill"))
                    .kill
                else if (std.mem.eql(u8, attr, "ignore"))
                    .ignore
                else
                    return error.UnknownPipelineAttr;
            }
        }
    }
    self.next_line();

    var inputs: std.ArrayList(Service.Pipeline.Input) = .empty;
    defer inputs.deinit(self.alloc);
    var keep: std.ArrayList(Service.Pipeline.Glob) = .empty;
    defer keep.deinit(self.alloc);
    var required_env: std.ArrayList([]const u8) = .empty;
    defer required_env.deinit(self.alloc);
    var env_bindings: std.ArrayList(struct { []const u8, Service.Pipeline.EnvBinding }) = .empty;
    defer env_bindings.deinit(self.alloc);
    var script: ?Service.Pipeline.Script = null;

    while (true) {
        self.skip_empty_lines();
        const ln = self.line orelse break;

        var ind: usize = 0;
        while (ind < ln.len and ln[ind] == ' ') ind += 1;

        if (ind == 0) break;
        if (ind != 2) return error.UnexpectedIndent;
        if (ind == ln.len) {
            self.next_line();
            continue;
        }

        self.idx = ind;

        switch (ln[self.idx]) {
            '<' => {
                self.idx += 1;
                _ = self.skip_spaces();

                if (self.ch() == '$') {
                    self.idx += 1;
                    const name = self.parse_name() orelse return error.NameExpected;
                    try required_env.append(self.alloc, name);
                    self.next_line();
                } else {
                    const consume = if (self.ch() == '&') blk: {
                        self.idx += 1;
                        _ = self.skip_spaces();
                        break :blk false;
                    } else true;

                    var namespace: ?[]const u8 = null;
                    var name = self.parse_key() orelse return error.NameExpected;
                    if (self.ch() == '.') {
                        self.idx += 1;
                        namespace = name;
                        name = self.parse_key() orelse return error.NameExpected;
                    }
                    _ = self.skip_spaces();

                    const exit_pattern: ?NumPattern(u8) = blk: {
                        if (self.ch()) |first_ch| {
                            if (NumPattern(u8).is_start(first_ch)) {
                                const pat_start = self.idx;
                                while (self.idx < ln.len and ln[self.idx] != ' ')
                                    self.idx += 1;
                                break :blk try NumPattern(u8).parse(self.alloc, ln[pat_start..self.idx]);
                            }
                        }
                        break :blk null;
                    };

                    if (namespace) |_|
                        return error.NamespaceNotSupported;

                    try inputs.append(self.alloc, .{
                        .target = .{
                            .exit_code = exit_pattern,
                            .pipeline = name,
                            .remote = "any",
                        },
                        .consume = consume,
                    });
                    self.next_line();
                }
            },

            '~' => {
                self.idx += 1;
                _ = self.skip_spaces();
                if (self.idx < ln.len) {
                    try keep.append(self.alloc, Service.Pipeline.Glob.parse(ln[self.idx..]));
                    self.next_line();
                } else {
                    return error.ExpectedPath;
                }
            },

            '$' => {
                const bind = try self.parse_env_binding_line();
                try env_bindings.append(self.alloc, bind);
            },

            '!' => {
                self.idx += 1;
                script = try self.parse_script();
            },

            '#' => self.next_line(),

            else => return error.UnexpectedToken,
        }
    }

    return .{
        .name = pipeline_name,
        .inputs = try inputs.toOwnedSlice(self.alloc),
        .keep = try keep.toOwnedSlice(self.alloc),
        .required_env = try required_env.toOwnedSlice(self.alloc),
        .env_bindings = try env_bindings.toOwnedSlice(self.alloc),
        .second_instance = second_instance,
        .script = script,
    };
}

pub fn parse_script(self: *@This()) !Service.Pipeline.Script {
    const lang = self.parse_name() orelse return error.NameExpected;
    _ = self.skip_spaces();

    const args: []const u8 = if (self.line) |ln|
        if (self.idx < ln.len) ln[self.idx..] else ""
    else
        "";

    self.next_line();

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(self.alloc);
    var base_indent: ?usize = null;

    while (self.line) |line| {
        var ind: usize = 0;
        while (ind < line.len and line[ind] == ' ') ind += 1;

        if (base_indent) |base| {
            if (ind < base) break;
            const content = if (ind < line.len) line[base..] else "";
            try lines.append(self.alloc, content);
        } else {
            if (line.len == 0 or ind == line.len) {
                self.next_line();
                continue;
            }
            if (ind == 0) break;
            base_indent = ind;
            try lines.append(self.alloc, line[ind..]);
        }
        self.next_line();
    }

    return .{
        .lang = lang,
        .args = args,
        .lines = try lines.toOwnedSlice(self.alloc),
    };
}

fn parse_env_binding_line(self: *@This()) !struct { []const u8, Service.Pipeline.EnvBinding } {
    std.debug.assert(self.ch() == '$');
    self.idx += 1;
    _ = self.skip_spaces();
    const var_name = self.parse_name() orelse return error.EnvNameExpected;
    _ = self.skip_spaces();
    const binding = try self.parse_env_value();
    self.next_line();
    return .{ var_name, binding };
}

fn parse_env_value(self: *@This()) !Service.Pipeline.EnvBinding {
    const ln = self.line orelse return error.ExpectedValue;
    if (self.idx >= ln.len) return error.ExpectedValue;

    if (ln[self.idx] == '&') {
        self.idx += 1;
        const namespace = self.parse_name() orelse return error.NameExpected;
        if (self.ch() != '.') return error.DotExpected;
        self.idx += 1;
        const key = self.parse_key() orelse return error.NameExpected;
        return resource_binding(namespace, key);
    }

    if (ln[self.idx] == '$') {
        self.idx += 1;
        const name = self.parse_name() orelse return error.NameExpected;
        return .{ .env_var = name };
    }

    const rest = ln[self.idx..];
    var has_interp = false;
    var j: usize = 0;
    while (j < rest.len) : (j += 1) {
        if (rest[j] == '{') {
            has_interp = true;
            break;
        }
        if (rest[j] == '\\' and j + 1 < rest.len and rest[j + 1] == '{') {
            has_interp = true;
            break;
        }
    }

    if (!has_interp) {
        const s = rest;
        self.idx = ln.len;
        return .{ .string = s };
    }

    return self.parse_interpolated();
}

fn resource_binding(namespace: []const u8, key: []const u8) Service.Pipeline.EnvBinding {
    if (std.mem.eql(u8, namespace, "databases")) return .{ .database = key };
    if (std.mem.eql(u8, namespace, "volumes")) return .{ .volume = key };
    if (std.mem.eql(u8, namespace, "ports")) return .{ .port = key };
    return .{ .string = key };
}

fn parse_interpolated(self: *@This()) !Service.Pipeline.EnvBinding {
    const ln = self.line.?;
    var segments: std.ArrayList(Service.Pipeline.EnvBinding) = .empty;
    defer segments.deinit(self.alloc);
    var lit: std.ArrayList(u8) = .empty;
    defer lit.deinit(self.alloc);

    while (self.idx < ln.len) {
        const c = ln[self.idx];

        if (c == '\\' and self.idx + 1 < ln.len and ln[self.idx + 1] == '{') {
            try lit.append(self.alloc, '{');
            self.idx += 2;
            continue;
        }

        if (c != '{') {
            try lit.append(self.alloc, c);
            self.idx += 1;
            continue;
        }

        if (lit.items.len > 0) {
            const s = try lit.toOwnedSlice(self.alloc);
            try segments.append(self.alloc, .{ .string = s });
        }
        self.idx += 1;

        if (self.idx < ln.len and ln[self.idx] == '$') {
            self.idx += 1;
            const name = self.parse_name() orelse return error.NameExpected;
            if (self.ch() != '}') return error.UnclosedBrace;
            self.idx += 1;
            try segments.append(self.alloc, .{ .env_var = name });
        } else if (self.idx < ln.len and ln[self.idx] == '&') {
            self.idx += 1;
            const ns = self.parse_name() orelse return error.NameExpected;
            if (self.ch() != '.') return error.DotExpected;
            self.idx += 1;
            const key = self.parse_key() orelse return error.NameExpected;
            if (self.ch() != '}') return error.UnclosedBrace;
            self.idx += 1;
            try segments.append(self.alloc, resource_binding(ns, key));
        } else {
            const start = self.idx;
            while (self.idx < ln.len and ln[self.idx] != '}') self.idx += 1;
            const text = try self.alloc.dupe(u8, ln[start..self.idx]);
            if (self.ch() != '}') return error.UnclosedBrace;
            self.idx += 1;
            try segments.append(self.alloc, .{ .string = text });
        }
    }

    if (lit.items.len > 0) {
        const s = try lit.toOwnedSlice(self.alloc);
        try segments.append(self.alloc, .{ .string = s });
    }

    if (segments.items.len == 1) return segments.pop().?;

    return .{ .interpolate = try segments.toOwnedSlice(self.alloc) };
}

pub fn print_trace(self: @This(), io: std.Io) !void {
    var buffer: [4 << 10]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &stderr_writer.interface;
    defer stderr_writer.flush() catch {};

    try stderr.print("\nParsing error at line {}:\n", .{self.ln + 1});

    const current_line = self.line orelse {
        try stderr.writeAll("<End of File>\n");
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

const testing = std.testing;

test "Parser - Workspace parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input =
        \\:name my_workspace
        \\:runtimes
        \\  :main_rs rust@1.7
        \\  :main_py python; cargo python-installer-fallback
        \\  :dua-cli cargo dua full,tokio-rt-thread
        \\  :postgresql pacman postgresql@1.7; apt postgresql; dnf postgresql,psql
        \\
        \\:databases
        \\  :main postgres
        \\  :other redis
        \\:volumes
        \\  :cache ram_fs max(10G)
        \\:ports
        \\  :frontend
        \\  :backend 1234
        \\  :foo engon.cm 1234
    ;

    var prs = @This().init(alloc, input) orelse return error.TestInitializationFailed;
    const ws = try prs.parse_workspace();

    try testing.expectEqualStrings("my_workspace", ws.name);

    const vols = ws.volumes.?;
    try testing.expectEqual(@as(usize, 1), vols.len);
    try testing.expectEqualStrings("cache", vols[0][0]);
    try testing.expect(vols[0][1].ram_fs);
    try testing.expectEqual(@as(?u64, 10 * 1024 * 1024 * 1024), vols[0][1].max_storage);

    const dbs = ws.databases.?;
    try testing.expectEqual(@as(usize, 2), dbs.len);
    try testing.expectEqualStrings("main", dbs[0][0]);
    try testing.expect(dbs[0][1] == .postgres);

    const ports = ws.ports.?;
    try testing.expectEqual(@as(usize, 3), ports.len);
    try testing.expectEqualStrings("backend", ports[1][0]);
    try testing.expectEqual(@as(?u16, 1234), ports[1][1].port);

    const runtimes = ws.runtimes.?;
    try testing.expectEqual(@as(usize, 4), runtimes.len);
    try testing.expectEqualStrings("main_rs", runtimes[0][0]);
}

test "Parser - Service parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input =
        \\:name eventra
        \\:workspace backend
        \\
        \\$ DATABASE_URL &databases.main
        \\$ STORAGE_URL &volumes.cache
        \\$ PLAIN_VAL simple string here
        \\
        \\< $REQUIRED_ENV
        \\
        \\.build safe(10)
        \\  < &src !0
        \\  < $REQUIRED_ENV_VAR
        \\  ~ target
        \\  $ BACKEND_PORT {simple string} here {$STORAGE_URL} fof {&ports.backend}-is\{escaped
        \\  !nu -cli args here
        \\    var foo = bar;
    ;

    var prs = @This().init(alloc, input) orelse return error.TestInitializationFailed;
    const svc = try prs.parse_service();

    try testing.expectEqualStrings("eventra", svc.name);
    try testing.expectEqualStrings("backend", svc.workspace.?);

    try testing.expectEqual(@as(usize, 3), svc.env_bindings.len);
    try testing.expectEqualStrings("DATABASE_URL", svc.env_bindings[0][0]);

    try testing.expectEqual(@as(usize, 1), svc.required_env.len);
    try testing.expectEqualStrings("REQUIRED_ENV", svc.required_env[0]);

    try testing.expectEqual(@as(usize, 1), svc.pipelines.len);
    const pipe = svc.pipelines[0];
    try testing.expectEqualStrings("build", pipe.name);
}
