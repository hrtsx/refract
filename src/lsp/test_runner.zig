const std = @import("std");

pub const Framework = enum {
    rspec,
    minitest,
    test_unit,
    cucumber,
    unknown,

    pub fn label(self: Framework) []const u8 {
        return switch (self) {
            .rspec => "rspec",
            .minitest => "minitest",
            .test_unit => "test-unit",
            .cucumber => "cucumber",
            .unknown => "unknown",
        };
    }
};

/// Detect a workspace's primary test framework. Cheap-checks file/dir markers
/// then falls back to scanning Gemfile.lock for the gem name.
pub fn detect(alloc: std.mem.Allocator, workspace_root: []const u8) Framework {
    if (dirExists(alloc, workspace_root, "spec")) return .rspec;
    if (fileExists(alloc, workspace_root, ".rspec")) return .rspec;
    if (dirExists(alloc, workspace_root, "features")) return .cucumber;
    if (dirExists(alloc, workspace_root, "test")) {
        const lock = readGemfileLock(alloc, workspace_root) catch null;
        if (lock) |bytes| {
            defer alloc.free(bytes);
            if (std.mem.indexOf(u8, bytes, "test-unit (") != null) return .test_unit;
        }
        return .minitest;
    }
    const lock = readGemfileLock(alloc, workspace_root) catch return .unknown;
    if (lock) |bytes| {
        defer alloc.free(bytes);
        if (std.mem.indexOf(u8, bytes, "rspec-core (") != null) return .rspec;
        if (std.mem.indexOf(u8, bytes, "cucumber (") != null) return .cucumber;
        if (std.mem.indexOf(u8, bytes, "minitest (") != null) return .minitest;
        if (std.mem.indexOf(u8, bytes, "test-unit (") != null) return .test_unit;
    }
    return .unknown;
}

/// Build the argv to run a single test at `file_path:line`. Caller frees.
pub fn buildRunArgv(
    alloc: std.mem.Allocator,
    fw: Framework,
    file_path: []const u8,
    line: ?u32,
) ![][]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer {
        for (argv.items) |a| alloc.free(@constCast(a));
        argv.deinit(alloc);
    }
    try argv.append(alloc, try alloc.dupe(u8, "bundle"));
    try argv.append(alloc, try alloc.dupe(u8, "exec"));

    switch (fw) {
        .rspec => {
            try argv.append(alloc, try alloc.dupe(u8, "rspec"));
            const target = if (line) |l|
                try std.fmt.allocPrint(alloc, "{s}:{d}", .{ file_path, l })
            else
                try alloc.dupe(u8, file_path);
            try argv.append(alloc, target);
        },
        .minitest => {
            try argv.append(alloc, try alloc.dupe(u8, "ruby"));
            try argv.append(alloc, try alloc.dupe(u8, "-Itest"));
            try argv.append(alloc, try alloc.dupe(u8, file_path));
            if (line) |l| {
                const arg = try std.fmt.allocPrint(alloc, "--name=/_at_line_{d}/", .{l});
                try argv.append(alloc, arg);
            }
        },
        .test_unit => {
            try argv.append(alloc, try alloc.dupe(u8, "ruby"));
            try argv.append(alloc, try alloc.dupe(u8, "-Itest"));
            try argv.append(alloc, try alloc.dupe(u8, file_path));
        },
        .cucumber => {
            try argv.append(alloc, try alloc.dupe(u8, "cucumber"));
            const target = if (line) |l|
                try std.fmt.allocPrint(alloc, "{s}:{d}", .{ file_path, l })
            else
                try alloc.dupe(u8, file_path);
            try argv.append(alloc, target);
        },
        .unknown => return error.UnknownFramework,
    }
    return try argv.toOwnedSlice(alloc);
}

pub fn freeArgv(alloc: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| alloc.free(@constCast(a));
    alloc.free(@constCast(argv));
}

fn dirExists(alloc: std.mem.Allocator, root: []const u8, sub: []const u8) bool {
    const path = std.fs.path.join(alloc, &.{ root, sub }) catch return false;
    defer alloc.free(path);
    var d = std.Io.Dir.cwd().openDir(std.Options.debug_io, path, .{}) catch return false;
    d.close(std.Options.debug_io);
    return true;
}

fn fileExists(alloc: std.mem.Allocator, root: []const u8, sub: []const u8) bool {
    const path = std.fs.path.join(alloc, &.{ root, sub }) catch return false;
    defer alloc.free(path);
    const f = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return false;
    f.close(std.Options.debug_io);
    return true;
}

fn readGemfileLock(alloc: std.mem.Allocator, root: []const u8) !?[]u8 {
    const path = try std.fs.path.join(alloc, &.{ root, "Gemfile.lock" });
    defer alloc.free(path);
    var f = std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{}) catch return null;
    defer f.close(std.Options.debug_io);
    var buf: [4096]u8 = undefined;
    var fr = f.readerStreaming(std.Options.debug_io, &buf);
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = fr.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try bytes.appendSlice(alloc, chunk[0..n]);
        if (bytes.items.len > 1 * 1024 * 1024) break;
    }
    return try bytes.toOwnedSlice(alloc);
}

test "detect rspec via spec/ dir" {
    const alloc = std.testing.allocator;
    const tmp = "/tmp/refract_testrunner_rspec";
    std.Io.Dir.cwd().createDir(std.Options.debug_io, tmp, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, tmp) catch {};
    const spec_dir = try std.fs.path.join(alloc, &.{ tmp, "spec" });
    defer alloc.free(spec_dir);
    std.Io.Dir.cwd().createDir(std.Options.debug_io, spec_dir, .default_dir) catch {};
    try std.testing.expectEqual(Framework.rspec, detect(alloc, tmp));
}

test "detect cucumber via features/ dir" {
    const alloc = std.testing.allocator;
    const tmp = "/tmp/refract_testrunner_cuke";
    std.Io.Dir.cwd().createDir(std.Options.debug_io, tmp, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, tmp) catch {};
    const features = try std.fs.path.join(alloc, &.{ tmp, "features" });
    defer alloc.free(features);
    std.Io.Dir.cwd().createDir(std.Options.debug_io, features, .default_dir) catch {};
    try std.testing.expectEqual(Framework.cucumber, detect(alloc, tmp));
}

test "buildRunArgv rspec includes file:line" {
    const alloc = std.testing.allocator;
    const argv = try buildRunArgv(alloc, .rspec, "spec/foo_spec.rb", 42);
    defer freeArgv(alloc, argv);
    try std.testing.expect(argv.len >= 4);
    try std.testing.expectEqualStrings("bundle", argv[0]);
    try std.testing.expectEqualStrings("rspec", argv[2]);
    try std.testing.expectEqualStrings("spec/foo_spec.rb:42", argv[3]);
}

test "buildRunArgv minitest invokes ruby with -Itest" {
    const alloc = std.testing.allocator;
    const argv = try buildRunArgv(alloc, .minitest, "test/foo_test.rb", null);
    defer freeArgv(alloc, argv);
    try std.testing.expectEqualStrings("ruby", argv[2]);
    try std.testing.expectEqualStrings("-Itest", argv[3]);
}

test "buildRunArgv unknown framework errors" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnknownFramework, buildRunArgv(alloc, .unknown, "x", null));
}
