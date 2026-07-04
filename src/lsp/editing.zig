const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");

pub fn resolveScopeId(self: *Server, file_id: i64, name: []const u8, cursor_line_1based: i64, cursor_col: i64) ?i64 {
    // Check local_vars writes at/before cursor (closest one wins)
    const lv = self.queryDb().prepare(
        \\SELECT scope_id FROM local_vars
        \\WHERE file_id=? AND name=? AND line<=?
        \\ORDER BY line DESC LIMIT 1
    ) catch return null;
    defer lv.finalize();
    lv.bind_int(1, file_id);
    lv.bind_text(2, name);
    lv.bind_int(3, cursor_line_1based);
    if (lv.step() catch false) {
        if (lv.column_type(0) != 5) return lv.column_int(0); // SQLITE_NULL=5
        return 0; // scope_id IS NULL means top-level local
    }
    // Check scoped refs at cursor position
    const rf = self.queryDb().prepare(
        \\SELECT scope_id FROM refs
        \\WHERE file_id=? AND name=? AND line=? AND col<=? AND scope_id IS NOT NULL
        \\LIMIT 1
    ) catch return null;
    defer rf.finalize();
    rf.bind_int(1, file_id);
    rf.bind_text(2, name);
    rf.bind_int(3, cursor_line_1based);
    rf.bind_int(4, cursor_col);
    if (rf.step() catch false) {
        if (rf.column_type(0) != 5) return rf.column_int(0);
    }
    return null;
}
