const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const erb_mapping = @import("erb_mapping.zig");
const editing = @import("editing.zig");
const hot_index_mod = @import("hot_index.zig");
const literal_receiver = @import("literal_receiver.zig");
const type_resolver = @import("type_resolver.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractParamsObject = S.extractParamsObject;
const extractPosition = S.extractPosition;
const uriToPath = S.uriToPath;
const emptyResult = S.emptyResult;
const writeEscapedJsonContent = S.writeEscapedJsonContent;
const writeEscapedJson = S.writeEscapedJson;
const writePathAsUri = S.writePathAsUri;
const getLineSlice = S.getLineSlice;
const extractWord = S.extractWord;
const extractQualifiedName = S.extractQualifiedName;
const extractBaseClass = S.extractBaseClass;
const utf8ColToUtf16 = S.utf8ColToUtf16;
const isInStringOrComment = S.isInStringOrComment;
const frcGet = S.frcGet;
const resolveRequireTarget = S.resolveRequireTarget;
const pathToUri = S.pathToUri;
const isRubyIdent = S.isRubyIdent;
const empty_json_array = S.empty_json_array;

// Write a single LSP Location object: {"uri":"file://<path>","range":{start..end}}.
// `line0` is 0-based; start/end are client (UTF-16) columns. Centralizes the
// {uri,range} JSON that the definition/references/highlight emitters all repeat.
pub fn writeLoc(w: *std.Io.Writer, path: []const u8, line0: i64, start_char: u32, end_char: u32) !void {
    try w.writeAll("{\"uri\":\"file://");
    try writePathAsUri(w, path);
    try w.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ line0, start_char, line0, end_char });
}

pub const DefOrigin = struct {
    line: u32,
    start_char: u32,
    end_char: u32,
};

/// Emit one definition entry (LocationLink or Location) for a symbol the
/// caller has already located. Mirrors the per-row emission inside the SQL
/// path of queryAndEmitDefinitions so hot-index and SQL paths produce
/// byte-identical JSON.
pub fn emitOneDef(
    self: *Server,
    w: *std.Io.Writer,
    sym_name: []const u8,
    sym_line: i64,
    sym_col: i64,
    sym_path: []const u8,
    found_any: *bool,
    frc: *std.StringHashMapUnmanaged([]const u8),
    origin: ?DefOrigin,
) !void {
    if (found_any.*) try w.writeByte(',');
    found_any.* = true;
    const start_char = self.toClientColFromPath(frc, sym_path, sym_line - 1, sym_col);
    if (self.client_caps_def_link) {
        try w.writeAll("{\"targetUri\":\"file://");
        try writePathAsUri(w, sym_path);
        try w.print("\",\"targetRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
            sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
        });
        try w.print(",\"targetSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
            sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
        });
        if (origin) |orig| {
            try w.print(",\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                orig.line, orig.start_char, orig.line, orig.end_char,
            });
        }
        try w.writeByte('}');
    } else {
        try writeLoc(w, sym_path, sym_line - 1, start_char, start_char + @as(u32, @intCast(sym_name.len)));
    }
}

/// Receiver-typed definition emit. Looks up `method_name` scoped to
/// `class_name` via `hot.lookupMethodOnClass` and emits a single canonical
/// location. Falls through silently when the hot index is unavailable or the
/// method isn't recorded for that class — caller continues with the unscoped
/// path. This is what makes `[1,2,3].first` land on `array.rbs` instead of
/// the first `first` symbol by row id.
pub fn emitDefinitionOnClass(
    self: *Server,
    w: *std.Io.Writer,
    method_name: []const u8,
    class_name: []const u8,
    found_any: *bool,
    frc: *std.StringHashMapUnmanaged([]const u8),
    origin: ?DefOrigin,
) !void {
    var hg = self.lockHot();
    defer hg.deinit();
    const hot = hg.hot orelse return;
    const base = if (class_name.len > 2 and class_name[0] == '[' and class_name[class_name.len - 1] == ']')
        class_name[1 .. class_name.len - 1]
    else
        class_name;
    const hs = hot.lookupMethodOnClass(base, method_name) orelse return;
    const sym_path = hot.pathFor(hs.file_id) orelse return;
    try emitOneDef(self, w, hs.name, @intCast(hs.line), @intCast(hs.col), sym_path, found_any, frc, origin);
}

/// Try to satisfy a definition lookup from the in-memory hot index. Returns
/// the number of results emitted. Caller falls back to SQL if zero.
/// Replicates the semantics of the SQL `s.name = ?` and qualified-suffix
/// branches; the rare mixin-walk case still goes to SQL.
pub fn tryEmitFromHotIndex(
    self: *Server,
    w: *std.Io.Writer,
    name: []const u8,
    found_any: *bool,
    frc: *std.StringHashMapUnmanaged([]const u8),
    origin: ?DefOrigin,
) !u32 {
    var hg = self.lockHot();
    defer hg.deinit();
    const hot = hg.hot orelse return 0;

    // Fast-fast path: pre-rendered def JSON, populated at warmup for the top-N
    // most-referenced unambiguous-def names. Skips the SQL+UTF-16-column work.
    if (self.client_caps_def_link) {
        if (hot.lookupPreDefLink(name)) |link_body| {
            if (found_any.*) try w.writeByte(',');
            found_any.* = true;
            try w.writeByte('{');
            try w.writeAll(link_body);
            if (origin) |orig| {
                try w.print(",\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                    orig.line, orig.start_char, orig.line, orig.end_char,
                });
            }
            try w.writeByte('}');
            return 1;
        }
    } else {
        if (hot.lookupPreDefLoc(name)) |loc_body| {
            if (found_any.*) try w.writeByte(',');
            found_any.* = true;
            try w.writeAll(loc_body);
            return 1;
        }
    }

    var emitted: u32 = 0;
    var seen: std.AutoHashMap(u64, void) = .init(self.alloc);
    defer seen.deinit();

    for (hot.lookupName(name)) |sym| {
        if (emitted >= 10) break;
        const path = hot.pathFor(sym.file_id) orelse continue;
        // RSpec example-description prose (`describe "new"`) is never a valid
        // go-to-def target for a code identifier. Routing-DSL names (`resource
        // :ship_address`) synthesize a `def`-kind symbol in a Rails routes file,
        // but those files define routes (→ routes table), not methods — so a
        // bare `recv.ship_address` should resolve to the model, not the route.
        if (sym.kind == .test_desc or sym.kind == .namespace_label) continue;
        if (sym.kind == .def and isRailsRoutesFile(path)) continue;
        const key = hashSymbol(sym);
        if (seen.contains(key)) continue;
        seen.put(key, {}) catch return emitted;
        try emitOneDef(self, w, sym.name, @intCast(sym.line), @intCast(sym.col), path, found_any, frc, origin);
        emitted += 1;
    }
    for (hot.lookupTail(name)) |sym| {
        if (emitted >= 10) break;
        if (!sym.kind.matchesQualifiedSuffix()) continue;
        const path = hot.pathFor(sym.file_id) orelse continue;
        const key = hashSymbol(sym);
        if (seen.contains(key)) continue;
        seen.put(key, {}) catch return emitted;
        try emitOneDef(self, w, sym.name, @intCast(sym.line), @intCast(sym.col), path, found_any, frc, origin);
        emitted += 1;
    }
    return emitted;
}

pub fn hashSymbol(sym: hot_index_mod.HotSymbol) u64 {
    return (@as(u64, sym.file_id) << 32) ^ (@as(u64, sym.line) << 16) ^ @as(u64, sym.col);
}

/// A Rails routes file holds routing DSL (resources/namespace/…), mapped to the
/// `routes` table, not method definitions. Used to keep synthesized routing-DSL
/// `def` symbols out of identifier go-to-def. Mirrors the SQL path-LIKE guards
/// in queryAndEmitDefinitions.
pub fn isRailsRoutesFile(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/config/routes") != null or
        std.mem.indexOf(u8, path, "/routes/") != null;
}

pub fn queryAndEmitDefinitions(self: *Server, w: *std.Io.Writer, name: []const u8, found_any: *bool, frc: *std.StringHashMapUnmanaged([]const u8), origin: ?DefOrigin, cursor_path: []const u8) !void {
    const hot_hits = tryEmitFromHotIndex(self, w, name, found_any, frc, origin) catch 0;
    if (hot_hits > 0) return;

    // Prefer a definition in the cursor's own file when the name collides across
    // files (e.g. same-named classes in different namespaces). A local definition
    // shadows; without this tie-break the first row is arbitrary (rowid order).
    const stmt_exact = try self.cachedStmt(
        \\SELECT s.name, s.line, s.col, f.path
        \\FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE s.name = ? AND s.kind NOT IN ('test', 'namespace')
        \\  AND NOT (s.kind = 'def' AND (f.path LIKE '%/config/routes%' OR f.path LIKE '%/routes/%'))
        \\ORDER BY (f.path = ?) DESC LIMIT 20
    );
    defer stmt_exact.reset();
    stmt_exact.bind_text(1, name);
    stmt_exact.bind_text(2, cursor_path);

    var found_count: usize = 0;
    while (try stmt_exact.step()) {
        if (found_any.*) try w.writeByte(',');
        found_any.* = true;
        found_count += 1;
        const sym_name = stmt_exact.column_text(0);
        const sym_line = stmt_exact.column_int(1);
        const sym_col = stmt_exact.column_int(2);
        const sym_path = stmt_exact.column_text(3);
        const start_char = self.toClientColFromPath(frc, sym_path, sym_line - 1, sym_col);
        if (self.client_caps_def_link) {
            // LocationLink format (LSP 3.14+)
            try w.writeAll("{\"targetUri\":\"file://");
            try writePathAsUri(w, sym_path);
            try w.print("\",\"targetRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
            });
            try w.print(",\"targetSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
            });
            if (origin) |orig| {
                try w.print(",\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                    orig.line, orig.start_char, orig.line, orig.end_char,
                });
            }
            try w.writeByte('}');
        } else {
            // Location format (legacy)
            try writeLoc(w, sym_path, sym_line - 1, start_char, start_char + @as(u32, @intCast(sym_name.len)));
        }
    }

    if (found_count == 0) {
        const stmt_qualified = try self.cachedStmt(
            \\SELECT s.name, s.line, s.col, f.path
            \\FROM symbols s JOIN files f ON s.file_id = f.id
            \\WHERE s.name LIKE '%::' || ? AND s.kind IN ('class','module','association','scope','validation','callback')
            \\LIMIT 10
        );
        defer stmt_qualified.reset();
        stmt_qualified.bind_text(1, name);
        while (try stmt_qualified.step()) {
            const sym_name = stmt_qualified.column_text(0);
            // SQLite LIKE is ASCII-case-insensitive, so `'%::' || 'rb'` also matches
            // `...::RB`. Re-confirm the `::name` suffix byte-exact so a lowercase
            // probe can't wrong-jump to a case-folded constant.
            if (!std.mem.endsWith(u8, sym_name, name) or
                sym_name.len < name.len + 2 or
                !std.mem.eql(u8, sym_name[sym_name.len - name.len - 2 .. sym_name.len - name.len], "::")) continue;
            if (found_any.*) try w.writeByte(',');
            found_any.* = true;
            found_count += 1;
            if (found_count > 10) break;
            const sym_line = stmt_qualified.column_int(1);
            const sym_col = stmt_qualified.column_int(2);
            const sym_path = stmt_qualified.column_text(3);
            const start_char = self.toClientColFromPath(frc, sym_path, sym_line - 1, sym_col);
            if (self.client_caps_def_link) {
                try w.writeAll("{\"targetUri\":\"file://");
                try writePathAsUri(w, sym_path);
                try w.print("\",\"targetRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                    sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
                });
                try w.print(",\"targetSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                    sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
                });
                if (origin) |orig| {
                    try w.print(",\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                        orig.line, orig.start_char, orig.line, orig.end_char,
                    });
                }
                try w.writeByte('}');
            } else {
                try writeLoc(w, sym_path, sym_line - 1, start_char, start_char + @as(u32, @intCast(sym_name.len)));
            }
        }

        if (found_count < 10) {
            const stmt_mixins = try self.cachedStmt(
                \\SELECT s2.name, s2.line, s2.col, f2.path
                \\FROM symbols s2 JOIN files f2 ON s2.file_id = f2.id
                \\JOIN mixins m ON s2.file_id IN (
                \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=m.module_name
                \\)
                \\WHERE s2.name = ? AND s2.kind = 'def'
                \\LIMIT 10
            );
            defer stmt_mixins.reset();
            stmt_mixins.bind_text(1, name);
            while (try stmt_mixins.step()) {
                if (found_any.*) try w.writeByte(',');
                found_any.* = true;
                found_count += 1;
                if (found_count > 10) break;
                const sym_name = stmt_mixins.column_text(0);
                const sym_line = stmt_mixins.column_int(1);
                const sym_col = stmt_mixins.column_int(2);
                const sym_path = stmt_mixins.column_text(3);
                const start_char = self.toClientColFromPath(frc, sym_path, sym_line - 1, sym_col);
                if (self.client_caps_def_link) {
                    try w.writeAll("{\"targetUri\":\"file://");
                    try writePathAsUri(w, sym_path);
                    try w.print("\",\"targetRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                        sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
                    });
                    try w.print(",\"targetSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                        sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
                    });
                    if (origin) |orig| {
                        try w.print(",\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                            orig.line, orig.start_char, orig.line, orig.end_char,
                        });
                    }
                    try w.writeByte('}');
                } else {
                    try writeLoc(w, sym_path, sym_line - 1, start_char, start_char + @as(u32, @intCast(sym_name.len)));
                }
            }
        }
    }
}
