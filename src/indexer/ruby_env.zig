const std = @import("std");

pub const RubyEnv = struct {
    version: ?[]u8, // e.g., "3.4.2"
    source: Source,
    ruby_path: ?[]u8, // resolved binary, may be null when only version is known

    pub const Source = enum {
        tool_versions, // asdf or mise
        ruby_version_file, // chruby/rbenv
        mise_toml,
        env_rbenv,
        env_chruby,
        path_default, // first `ruby` on PATH

        pub fn label(self: Source) []const u8 {
            return switch (self) {
                .tool_versions => ".tool-versions",
                .ruby_version_file => ".ruby-version",
                .mise_toml => "mise.toml",
                .env_rbenv => "$RBENV_VERSION",
                .env_chruby => "$CHRUBY_VERSION",
                .path_default => "PATH",
            };
        }
    };

    pub fn deinit(self: *RubyEnv, alloc: std.mem.Allocator) void {
        if (self.version) |v| alloc.free(v);
        if (self.ruby_path) |p| alloc.free(p);
        self.version = null;
        self.ruby_path = null;
    }
};

/// Detect active Ruby for `workspace_root`. Order matches plan R1:
/// 1. .tool-versions (asdf/mise) — line `ruby <ver>`
/// 2. .ruby-version (chruby/rbenv) — single line
/// 3. mise.toml — `[tools]\nruby = "<ver>"`
/// 4. $RBENV_VERSION
/// 5. $CHRUBY_VERSION
/// 6. fallback: empty (caller falls back to PATH `ruby`)
pub fn detect(alloc: std.mem.Allocator, workspace_root: []const u8) !RubyEnv {
    if (try readToolVersions(alloc, workspace_root)) |v| {
        return RubyEnv{ .version = v, .source = .tool_versions, .ruby_path = null };
    }
    if (try readRubyVersionFile(alloc, workspace_root)) |v| {
        return RubyEnv{ .version = v, .source = .ruby_version_file, .ruby_path = null };
    }
    if (try readMiseToml(alloc, workspace_root)) |v| {
        return RubyEnv{ .version = v, .source = .mise_toml, .ruby_path = null };
    }
    if (std.c.getenv("RBENV_VERSION")) |p| {
        const v = try alloc.dupe(u8, std.mem.span(p));
        return RubyEnv{ .version = v, .source = .env_rbenv, .ruby_path = null };
    }
    if (std.c.getenv("CHRUBY_VERSION")) |p| {
        const v = try alloc.dupe(u8, std.mem.span(p));
        return RubyEnv{ .version = v, .source = .env_chruby, .ruby_path = null };
    }
    return RubyEnv{ .version = null, .source = .path_default, .ruby_path = null };
}

fn readFileBytes(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    var file = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return null;
    defer file.close(std.Options.debug_io);
    var buf: [4096]u8 = undefined;
    var fr = file.readerStreaming(std.Options.debug_io, &buf);
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = fr.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try bytes.appendSlice(alloc, chunk[0..n]);
        if (bytes.items.len > 256 * 1024) break;
    }
    return try bytes.toOwnedSlice(alloc);
}

fn readToolVersions(alloc: std.mem.Allocator, root: []const u8) !?[]u8 {
    const path = try std.fs.path.join(alloc, &.{ root, ".tool-versions" });
    defer alloc.free(path);
    const bytes = (try readFileBytes(alloc, path)) orelse return null;
    defer alloc.free(bytes);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "ruby ") and !std.mem.startsWith(u8, trimmed, "ruby\t")) continue;
        const after = std.mem.trim(u8, trimmed["ruby".len..], " \t");
        if (after.len == 0) continue;
        return try alloc.dupe(u8, after);
    }
    return null;
}

fn readRubyVersionFile(alloc: std.mem.Allocator, root: []const u8) !?[]u8 {
    const path = try std.fs.path.join(alloc, &.{ root, ".ruby-version" });
    defer alloc.free(path);
    const bytes = (try readFileBytes(alloc, path)) orelse return null;
    defer alloc.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

fn readMiseToml(alloc: std.mem.Allocator, root: []const u8) !?[]u8 {
    const path = try std.fs.path.join(alloc, &.{ root, "mise.toml" });
    defer alloc.free(path);
    const bytes = (try readFileBytes(alloc, path)) orelse return null;
    defer alloc.free(bytes);
    // Cheap [tools] table scan — matches `ruby = "<ver>"` lines.
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var in_tools = false;
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (trimmed[0] == '[') {
            in_tools = std.mem.eql(u8, trimmed, "[tools]");
            continue;
        }
        if (!in_tools) continue;
        if (!std.mem.startsWith(u8, trimmed, "ruby")) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const rhs = std.mem.trim(u8, trimmed[eq + 1 ..], " \t\"'");
        if (rhs.len == 0) continue;
        return try alloc.dupe(u8, rhs);
    }
    return null;
}

test "detect picks .tool-versions over .ruby-version" {
    const alloc = std.testing.allocator;
    const tmp = "/tmp/refract_ruby_env_test";
    std.Io.Dir.cwd().createDir(std.Options.debug_io, tmp, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, tmp) catch {};
    {
        const tv = try std.fs.path.join(alloc, &.{ tmp, ".tool-versions" });
        defer alloc.free(tv);
        var f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, tv, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "ruby 3.4.2\nnodejs 22.0.0\n");
    }
    {
        const rv = try std.fs.path.join(alloc, &.{ tmp, ".ruby-version" });
        defer alloc.free(rv);
        var f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, rv, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "2.7.8\n");
    }
    var env = try detect(alloc, tmp);
    defer env.deinit(alloc);
    try std.testing.expect(env.version != null);
    try std.testing.expectEqualStrings("3.4.2", env.version.?);
    try std.testing.expectEqual(RubyEnv.Source.tool_versions, env.source);
}

test "detect falls back to .ruby-version" {
    const alloc = std.testing.allocator;
    const tmp = "/tmp/refract_ruby_env_test2";
    std.Io.Dir.cwd().createDir(std.Options.debug_io, tmp, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, tmp) catch {};
    {
        const rv = try std.fs.path.join(alloc, &.{ tmp, ".ruby-version" });
        defer alloc.free(rv);
        var f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, rv, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "3.2.0\n");
    }
    var env = try detect(alloc, tmp);
    defer env.deinit(alloc);
    try std.testing.expectEqualStrings("3.2.0", env.version.?);
    try std.testing.expectEqual(RubyEnv.Source.ruby_version_file, env.source);
}

test "detect parses mise.toml [tools] ruby" {
    const alloc = std.testing.allocator;
    const tmp = "/tmp/refract_ruby_env_test3";
    std.Io.Dir.cwd().createDir(std.Options.debug_io, tmp, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, tmp) catch {};
    {
        const mt = try std.fs.path.join(alloc, &.{ tmp, "mise.toml" });
        defer alloc.free(mt);
        var f = try std.Io.Dir.cwd().createFile(std.Options.debug_io, mt, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io,
            \\[tools]
            \\ruby = "3.3.5"
            \\nodejs = "22"
            \\
        );
    }
    var env = try detect(alloc, tmp);
    defer env.deinit(alloc);
    try std.testing.expectEqualStrings("3.3.5", env.version.?);
    try std.testing.expectEqual(RubyEnv.Source.mise_toml, env.source);
}

test "detect returns path_default when no markers present" {
    const alloc = std.testing.allocator;
    const tmp = "/tmp/refract_ruby_env_empty";
    std.Io.Dir.cwd().createDir(std.Options.debug_io, tmp, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, tmp) catch {};
    var env = try detect(alloc, tmp);
    defer env.deinit(alloc);
    if (env.source == .env_rbenv or env.source == .env_chruby) return; // running shell sets these — accept
    try std.testing.expectEqual(RubyEnv.Source.path_default, env.source);
    try std.testing.expect(env.version == null);
}
