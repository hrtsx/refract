const std = @import("std");
const db_mod = @import("../db.zig");
const overlay = @import("../lsp/overlay.zig");

const io = std.Options.debug_io;

fn openDb() !db_mod.Db {
    const db = try db_mod.Db.open(":memory:");
    try db.init_schema();
    return db;
}

fn count(db: db_mod.Db, sql: [*:0]const u8) i64 {
    const stmt = db.prepare(sql) catch return -1;
    defer stmt.finalize();
    if (stmt.step() catch false) return stmt.column_int(0);
    return -1;
}

fn seed(db: db_mod.Db) !void {
    _ = try overlay.addNode(db, "proj1", "feat", "App::User", "concept", "user model", "the central user record", false, "doc", 1000) orelse return error.WriteFailed;
    _ = try overlay.addEdge(db, "proj1", "feat", "App::User", "App::Account", "uses", null, false, "rel", 1001) orelse return error.WriteFailed;
    _ = try overlay.addType(db, "proj1", null, "App::User", "name", -1, "String", false, "ret", 1002) orelse return error.WriteFailed;
    _ = try overlay.addSuppress(db, "proj1", "feat", "App::User", null, "refract/nil-receiver", null, false, "fp", 1003) orelse return error.WriteFailed;
}

test "export then import into a fresh db round-trips every kind" {
    const alloc = std.testing.allocator;
    const path = "/tmp/refract_overlay_roundtrip.json";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const src = try openDb();
    defer src.close();
    try seed(src);
    try overlay.exportJson(src, alloc, "proj1", path);

    const dst = try openDb();
    defer dst.close();
    const added = try overlay.importJson(dst, alloc, "proj1", path);
    try std.testing.expectEqual(@as(u32, 4), added);

    try std.testing.expectEqual(@as(i64, 1), count(dst, "SELECT COUNT(*) FROM overlay_nodes WHERE revoked_at IS NULL"));
    try std.testing.expectEqual(@as(i64, 1), count(dst, "SELECT COUNT(*) FROM overlay_edges WHERE revoked_at IS NULL"));
    try std.testing.expectEqual(@as(i64, 1), count(dst, "SELECT COUNT(*) FROM overlay_types WHERE revoked_at IS NULL"));
    try std.testing.expectEqual(@as(i64, 1), count(dst, "SELECT COUNT(*) FROM overlay_suppress WHERE revoked_at IS NULL"));

    const t = overlay.effectiveType(dst, alloc, "proj1", "feat", "App::User", "name", -1) orelse return error.NoType;
    defer alloc.free(t);
    try std.testing.expectEqualStrings("String", t);
    try std.testing.expect(overlay.isSuppressed(dst, "proj1", "feat", "refract/nil-receiver", null, null, "App::User"));
}

test "re-importing the same file is idempotent" {
    const alloc = std.testing.allocator;
    const path = "/tmp/refract_overlay_idem.json";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const src = try openDb();
    defer src.close();
    try seed(src);
    try overlay.exportJson(src, alloc, "proj1", path);

    const dst = try openDb();
    defer dst.close();
    try std.testing.expectEqual(@as(u32, 4), try overlay.importJson(dst, alloc, "proj1", path));
    // Second import must add nothing and leave row counts untouched.
    try std.testing.expectEqual(@as(u32, 0), try overlay.importJson(dst, alloc, "proj1", path));
    try std.testing.expectEqual(@as(i64, 1), count(dst, "SELECT COUNT(*) FROM overlay_nodes WHERE revoked_at IS NULL"));
    try std.testing.expectEqual(@as(i64, 1), count(dst, "SELECT COUNT(*) FROM overlay_edges WHERE revoked_at IS NULL"));
}

test "import refuses an unknown schema version" {
    const alloc = std.testing.allocator;
    const path = "/tmp/refract_overlay_badschema.json";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"schema\":2,\"project_id\":\"proj1\",\"nodes\":[{\"branch\":null,\"fqn\":\"X\",\"kind\":\"note\",\"label\":null,\"content\":null,\"source\":\"AGENT\",\"confidence\":70,\"reason\":\"r\",\"created_at\":1}]}\n" });

    const dst = try openDb();
    defer dst.close();
    try std.testing.expectEqual(@as(u32, 0), try overlay.importJson(dst, alloc, "proj1", path));
    try std.testing.expectEqual(@as(i64, 0), count(dst, "SELECT COUNT(*) FROM overlay_nodes WHERE revoked_at IS NULL"));
}

test "branch type override wins over global, falls back after revert" {
    const alloc = std.testing.allocator;
    const db = try openDb();
    defer db.close();

    _ = try overlay.addType(db, "proj1", null, "X", "m", -1, "GlobalT", false, "g", 1) orelse return error.WriteFailed;
    const bid = try overlay.addType(db, "proj1", "b1", "X", "m", -1, "BranchT", false, "b", 2) orelse return error.WriteFailed;

    {
        const t = overlay.effectiveType(db, alloc, "proj1", "b1", "X", "m", -1) orelse return error.NoType;
        defer alloc.free(t);
        try std.testing.expectEqualStrings("BranchT", t);
    }

    try std.testing.expect(overlay.revoke(db, alloc, "overlay_types", bid, 3));

    {
        const t = overlay.effectiveType(db, alloc, "proj1", "b1", "X", "m", -1) orelse return error.NoType;
        defer alloc.free(t);
        try std.testing.expectEqualStrings("GlobalT", t);
    }
}

test "promote is idempotent and keeps the branch row" {
    const alloc = std.testing.allocator;
    const db = try openDb();
    defer db.close();

    _ = try overlay.addNode(db, "proj1", "b1", "Y", "note", "n", null, false, "r", 1) orelse return error.WriteFailed;

    try std.testing.expect(overlay.promote(db, alloc, "proj1", "b1", 10) >= 1);
    try std.testing.expectEqual(@as(i64, 1), count(db, "SELECT COUNT(*) FROM overlay_nodes WHERE branch IS NULL AND revoked_at IS NULL"));

    // A second promote must not duplicate the global twin.
    try std.testing.expectEqual(@as(u32, 0), overlay.promote(db, alloc, "proj1", "b1", 11));
    try std.testing.expectEqual(@as(i64, 1), count(db, "SELECT COUNT(*) FROM overlay_nodes WHERE branch IS NULL AND revoked_at IS NULL"));
    // Branch-scoped original survives the promote.
    try std.testing.expectEqual(@as(i64, 1), count(db, "SELECT COUNT(*) FROM overlay_nodes WHERE branch='b1' AND revoked_at IS NULL"));
}

test "revoke soft-deletes once" {
    const alloc = std.testing.allocator;
    const db = try openDb();
    defer db.close();

    const id = try overlay.addNode(db, "proj1", "b1", "Z", "tag", "t", null, false, "r", 1) orelse return error.WriteFailed;
    try std.testing.expectEqual(@as(i64, 1), count(db, "SELECT COUNT(*) FROM overlay_nodes WHERE revoked_at IS NULL"));
    try std.testing.expect(overlay.revoke(db, alloc, "overlay_nodes", id, 2));
    try std.testing.expectEqual(@as(i64, 0), count(db, "SELECT COUNT(*) FROM overlay_nodes WHERE revoked_at IS NULL"));
    // Re-revoking a dead row is a no-op.
    try std.testing.expect(!overlay.revoke(db, alloc, "overlay_nodes", id, 3));
}
