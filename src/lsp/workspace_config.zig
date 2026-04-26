const std = @import("std");

const MAX_CONFIG_BYTES: usize = 64 * 1024;

pub const ApplyResult = struct {
    found: bool,
    parse_error: bool = false,
    keys_applied: u32 = 0,
};

pub const WorkspaceRecord = struct {
    id: i64,
    workspace_uri: []const u8,
    root_path: []const u8,
    is_primary: bool,
};

pub fn recordWorkspace(server: anytype, workspace_uri: []const u8, root_path: []const u8, is_primary: bool) ?i64 {
    const stmt = server.db.prepare(
        "INSERT OR REPLACE INTO worktree(workspace_uri, root_path, gemfile_path, ruby_version, is_primary, created_at) VALUES(?,?,?,?,?,?)",
    ) catch return null;
    defer stmt.finalize();
    stmt.bind_text(1, workspace_uri);
    stmt.bind_text(2, root_path);
    stmt.bind_null(3);
    stmt.bind_null(4);
    stmt.bind_int(5, if (is_primary) 1 else 0);
    stmt.bind_int(6, @divFloor(std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(), 1000));
    _ = stmt.step() catch return null;
    const id_stmt = server.db.prepare("SELECT id FROM worktree WHERE workspace_uri = ?") catch return null;
    defer id_stmt.finalize();
    id_stmt.bind_text(1, workspace_uri);
    if (id_stmt.step() catch false) {
        return id_stmt.column_int(0);
    }
    return null;
}

pub fn removeWorkspace(server: anytype, workspace_uri: []const u8) void {
    const stmt = server.db.prepare("DELETE FROM worktree WHERE workspace_uri = ?") catch return;
    defer stmt.finalize();
    stmt.bind_text(1, workspace_uri);
    _ = stmt.step() catch {};
}

pub fn listWorkspaces(server: anytype, alloc: std.mem.Allocator) ![]WorkspaceRecord {
    var out = std.ArrayList(WorkspaceRecord).empty;
    errdefer {
        for (out.items) |r| {
            alloc.free(r.workspace_uri);
            alloc.free(r.root_path);
        }
        out.deinit(alloc);
    }
    const stmt = server.db.prepare("SELECT id, workspace_uri, root_path, is_primary FROM worktree ORDER BY is_primary DESC, id ASC") catch return out.toOwnedSlice(alloc);
    defer stmt.finalize();
    while (stmt.step() catch false) {
        const id = stmt.column_int(0);
        const uri = try alloc.dupe(u8, stmt.column_text(1));
        errdefer alloc.free(uri);
        const rp = try alloc.dupe(u8, stmt.column_text(2));
        errdefer alloc.free(rp);
        const is_primary = stmt.column_int(3) != 0;
        try out.append(alloc, .{ .id = id, .workspace_uri = uri, .root_path = rp, .is_primary = is_primary });
    }
    return try out.toOwnedSlice(alloc);
}

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
