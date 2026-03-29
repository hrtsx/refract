const std = @import("std");

const MAX_CONFIG_BYTES: usize = 64 * 1024;

pub const ApplyResult = struct {
    found: bool,
    parse_error: bool = false,
    keys_applied: u32 = 0,
};

pub fn loadAndApply(server: anytype, root_path: []const u8) ApplyResult {
    var path_buf: [1024]u8 = undefined;
    const cfg_path = std.fmt.bufPrint(&path_buf, "{s}/.refractrc.json", .{root_path}) catch return .{ .found = false };

    const data = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, cfg_path, server.alloc, std.Io.Limit.limited(MAX_CONFIG_BYTES)) catch return .{ .found = false };
    defer server.alloc.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, server.alloc, data, .{}) catch return .{ .found = true, .parse_error = true };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{ .found = true, .parse_error = true },
    };

    var applied: u32 = 0;

    if (obj.get("disableTypeChecker")) |v| if (v == .bool) {
        server.disable_type_checker.store(v.bool, .monotonic);
        applied += 1;
    };

    if (obj.get("typeCheckerSeverity")) |v| if (v == .string) {
        const sev: u8 = if (std.mem.eql(u8, v.string, "error")) 1 else if (std.mem.eql(u8, v.string, "info")) 3 else 2;
        server.type_checker_severity.store(sev, .monotonic);
        applied += 1;
    };

    if (obj.get("indexBudget")) |bv| if (bv == .object) {
        if (bv.object.get("fileSizeMb")) |v| if (v == .integer and v.integer > 0) {
            const mb: i64 = @min(v.integer, 2048);
            server.max_file_size.store(@as(usize, @intCast(mb)) * 1024 * 1024, .monotonic);
            applied += 1;
        };
        if (bv.object.get("excludeDirs")) |v| if (v == .array) {
            var dirs = std.ArrayList([]const u8).empty;
            for (v.array.items) |item| if (item == .string) {
                const owned = server.alloc.dupe(u8, item.string) catch continue;
                dirs.append(server.alloc, owned) catch {
                    server.alloc.free(owned);
                    continue;
                };
            };
            const owned_slice = dirs.toOwnedSlice(server.alloc) catch &.{};
            if (owned_slice.len > 0) {
                server.extra_exclude_dirs = owned_slice;
                applied += 1;
            }
        };
    };

    if (obj.get("diagnosticsSuppressions")) |v| if (v == .array) {
        for (v.array.items) |item| if (item == .string) {
            const owned = server.alloc.dupe(u8, item.string) catch continue;
            server.disabled_diag_codes.append(server.alloc, owned) catch {
                server.alloc.free(owned);
            };
        };
        applied += 1;
    };

    return .{ .found = true, .parse_error = false, .keys_applied = applied };
}
