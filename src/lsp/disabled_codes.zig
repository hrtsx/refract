const std = @import("std");

pub const DisabledSet = struct {
    codes: std.StringHashMapUnmanaged(void) = .{},
    arena: std.heap.ArenaAllocator,

    pub fn init(parent: std.mem.Allocator) DisabledSet {
        return .{ .arena = std.heap.ArenaAllocator.init(parent) };
    }

    pub fn deinit(self: *DisabledSet) void {
        self.arena.deinit();
    }

    pub fn contains(self: *const DisabledSet, code: []const u8) bool {
        return self.codes.contains(code);
    }
};

pub fn loadFromWorkspace(parent: std.mem.Allocator, root_path: []const u8) DisabledSet {
    var set = DisabledSet.init(parent);
    errdefer set.deinit();

    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.refract/disabled.txt", .{root_path}) catch return set;

    const max_size: usize = 64 * 1024;
    const data = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, set.arena.allocator(), std.Io.Limit.limited(max_size)) catch return set;

    var line_it = std.mem.splitScalar(u8, data, '\n');
    while (line_it.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, '#')) |hash| {
            line = std.mem.trim(u8, line[0..hash], " \t");
            if (line.len == 0) continue;
        }
        const dup = set.arena.allocator().dupe(u8, line) catch continue;
        set.codes.put(set.arena.allocator(), dup, {}) catch {};
    }
    return set;
}

pub fn appendCode(root_path: []const u8, code: []const u8) !void {
    var dir_buf: [1024]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.refract", .{root_path});
    std.Io.Dir.createDirAbsolute(std.Options.debug_io, dir_path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var file_buf: [1024]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_buf, "{s}/disabled.txt", .{dir_path});

    var stack_buf: [4096]u8 = undefined;
    var existing_len: usize = 0;
    if (std.Io.Dir.cwd().readFile(std.Options.debug_io, file_path, &stack_buf)) |slice| {
        existing_len = slice.len;
    } else |_| {}

    if (existing_len > 0) {
        const last_idx = existing_len - 1;
        if (stack_buf[last_idx] != '\n') {
            if (existing_len < stack_buf.len) {
                stack_buf[existing_len] = '\n';
                existing_len += 1;
            }
        }

        var line_it = std.mem.splitScalar(u8, stack_buf[0..existing_len], '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.eql(u8, line, code)) return;
        }
    }

    if (existing_len + code.len + 1 > stack_buf.len) return error.FileTooLarge;
    @memcpy(stack_buf[existing_len .. existing_len + code.len], code);
    stack_buf[existing_len + code.len] = '\n';

    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = file_path,
        .data = stack_buf[0 .. existing_len + code.len + 1],
    });
}

test "DisabledSet parses comments and trims" {
    var set = DisabledSet.init(std.testing.allocator);
    defer set.deinit();
    const sample =
        "# leading comment\n" ++
        "refract/nil-receiver\n" ++
        "  refract/wrong-arity   \n" ++
        "\n" ++
        "refract/foo # trailing comment\n";
    var line_it = std.mem.splitScalar(u8, sample, '\n');
    while (line_it.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, '#')) |hash| {
            line = std.mem.trim(u8, line[0..hash], " \t");
            if (line.len == 0) continue;
        }
        const dup = try set.arena.allocator().dupe(u8, line);
        try set.codes.put(set.arena.allocator(), dup, {});
    }
    try std.testing.expect(set.contains("refract/nil-receiver"));
    try std.testing.expect(set.contains("refract/wrong-arity"));
    try std.testing.expect(set.contains("refract/foo"));
    try std.testing.expect(!set.contains("refract/bogus"));
}
