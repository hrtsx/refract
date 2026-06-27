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

const nav_symbols = @import("navigation_symbols.zig");
const writeLoc = nav_symbols.writeLoc;
const DefOrigin = nav_symbols.DefOrigin;
const emitOneDef = nav_symbols.emitOneDef;
const emitDefinitionOnClass = nav_symbols.emitDefinitionOnClass;
const tryEmitFromHotIndex = nav_symbols.tryEmitFromHotIndex;
const queryAndEmitDefinitions = nav_symbols.queryAndEmitDefinitions;

pub fn handleReferences(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    const rtx = self.beginRead();
    defer rtx.end();
    const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
    const pos = extractPosition(msg.params) orelse return emptyResult(msg);
    const line: u32 = pos.line;
    const character: u32 = pos.character;
    var include_decl: bool = true;
    if (msg.params) |params_val| {
        if (params_val == .object) {
            if (params_val.object.get("context")) |ctx_val| {
                if (ctx_val == .object) {
                    if (ctx_val.object.get("includeDeclaration")) |id_val| {
                        if (id_val == .bool) include_decl = id_val.bool;
                    }
                }
            }
        }
    }

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch
        return emptyResult(msg);
    defer self.alloc.free(source);

    const offset = self.clientPosToOffset(source, line, character);

    if (std.mem.endsWith(u8, path, ".erb") and !erb_mapping.isErbRubyContext(source, offset))
        return emptyResult(msg);

    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    const cursor_line_1based: i64 = @intCast(line + 1);
    var ref_word_start: usize = offset;
    while (ref_word_start > 0 and isRubyIdent(source[ref_word_start - 1])) ref_word_start -= 1;
    var ref_line_start: usize = 0;
    var ri: usize = 0;
    while (ri < ref_word_start) : (ri += 1) {
        if (source[ri] == '\n') ref_line_start = ri + 1;
    }
    const ref_col_0: i64 = @intCast(ref_word_start - ref_line_start);

    // Check if cursor is on a local variable; if so, scope the query
    var ref_scope_id: ?i64 = null;
    var is_local_ref = false;
    var ref_fid: i64 = 0;
    {
        const file_stmt_ref = try self.cachedStmt("SELECT id FROM files WHERE path = ?");
        defer file_stmt_ref.reset();
        file_stmt_ref.bind_text(1, path);
        if (try file_stmt_ref.step()) {
            ref_fid = file_stmt_ref.column_int(0);
            if (editing.resolveScopeId(self, ref_fid, word, cursor_line_1based, ref_col_0)) |sid| {
                // resolveScopeId also matches scoped *refs* — which include method
                // calls inside a method body, not just locals. Confirm the name is a
                // genuine local variable (every local has a write row in local_vars)
                // before scoping the query; otherwise a call-site reference would be
                // routed to the scoped branch and miss its cross-file declaration.
                const lv_guard = try self.cachedStmt("SELECT 1 FROM local_vars WHERE file_id=? AND name=? LIMIT 1");
                defer lv_guard.reset();
                lv_guard.bind_int(1, ref_fid);
                lv_guard.bind_text(2, word);
                if (try lv_guard.step()) {
                    is_local_ref = true;
                    ref_scope_id = if (sid != 0) sid else null;
                }
            }
        }
    }

    // Engage binding-exact scoping only when the name actually collides (defined in
    // >1 place) — that's the over-collection case. A uniquely-named symbol (incl.
    // top-level methods whose calls have no enclosing class, so no def_id) is already
    // complete and correct via the name-global path; scoping it would under-report.
    var name_collision = false;
    if (!is_local_ref and ref_fid != 0) {
        const cstmt = try self.cachedStmt("SELECT COUNT(*) FROM symbols WHERE name=? AND kind IN ('def','classdef','class','module','moduledef','constant')");
        defer cstmt.reset();
        cstmt.bind_text(1, word);
        if (try cstmt.step()) name_collision = cstmt.column_int(0) > 1;
    }

    // Binding-exact path: if the cursor token resolves to a single definition
    // (refs.def_id populated at index time, or the cursor sits on the decl itself),
    // return only that binding's refs + decl rather than every same-named token. A
    // zero/NULL def_id falls through to the name-global query below (no regression).
    var cursor_def_id: i64 = 0;
    if (!is_local_ref and ref_fid != 0 and name_collision) {
        const dq = try self.cachedStmt("SELECT def_id FROM refs WHERE file_id=? AND name=? AND line=? AND col=? AND def_id IS NOT NULL LIMIT 1");
        defer dq.reset();
        dq.bind_int(1, ref_fid);
        dq.bind_text(2, word);
        dq.bind_int(3, cursor_line_1based);
        dq.bind_int(4, ref_col_0);
        if (try dq.step()) {
            cursor_def_id = dq.column_int(0);
        } else {
            const sq = try self.cachedStmt("SELECT id FROM symbols WHERE file_id=? AND name=? AND line=? AND kind IN ('def','constant','class','module','classdef') LIMIT 1");
            defer sq.reset();
            sq.bind_int(1, ref_fid);
            sq.bind_text(2, word);
            sq.bind_int(3, cursor_line_1based);
            if (try sq.step()) cursor_def_id = sq.column_int(0);
        }
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;
    var frc_ref: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_ref.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_ref.deinit(self.alloc);
    }

    if (cursor_def_id != 0) {
        // Binding-exact: every ref resolved to this definition, plus the decl site.
        // Deduped by (path,line,col) — the visitor sometimes over-inserts a ref at a
        // def line, which would otherwise collide with the decl emit.
        var seen_loc: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var sit = seen_loc.keyIterator();
            while (sit.next()) |k| self.alloc.free(k.*);
            seen_loc.deinit(self.alloc);
        }
        const def_ref = if (include_decl)
            try self.cachedStmt(
                \\SELECT f.path, r.line, r.col FROM refs r JOIN files f ON r.file_id=f.id WHERE r.def_id=?
            )
        else
            try self.cachedStmt(
                \\SELECT f.path, r.line, r.col FROM refs r JOIN files f ON r.file_id=f.id WHERE r.def_id=?
                \\AND NOT EXISTS (
                \\  SELECT 1 FROM symbols s WHERE s.file_id=r.file_id AND s.name=r.name AND s.line=r.line
                \\    AND (s.col=r.col OR s.kind IN ('class','module'))
                \\)
            );
        defer def_ref.reset();
        def_ref.bind_int(1, cursor_def_id);
        var dr_i: usize = 0;
        while (try def_ref.step()) {
            dr_i += 1;
            if ((dr_i & 0xFF) == 0 and self.isCancelled(msg.id)) {
                aw.deinit();
                return self.cancelledResponse(msg.id);
            }
            const rp = def_ref.column_text(0);
            const rl = def_ref.column_int(1);
            const rc = def_ref.column_int(2);
            const key = std.fmt.allocPrint(self.alloc, "{s}\x00{d}\x00{d}", .{ rp, rl, rc }) catch continue;
            const gop = seen_loc.getOrPut(self.alloc, key) catch {
                self.alloc.free(key);
                continue;
            };
            if (gop.found_existing) {
                self.alloc.free(key);
                continue;
            }
            const rc_client = self.toClientColFromPath(&frc_ref, rp, rl - 1, rc);
            if (!first) try w.writeByte(',');
            first = false;
            try writeLoc(w, rp, rl - 1, rc_client, rc_client + @as(u32, @intCast(word.len)));
        }
        if (include_decl) {
            const decl_one = try self.cachedStmt(
                \\SELECT f.path, s.line, s.col FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.id=?
            );
            defer decl_one.reset();
            decl_one.bind_int(1, cursor_def_id);
            if (try decl_one.step()) {
                const dp = decl_one.column_text(0);
                const dl = decl_one.column_int(1);
                const dc = decl_one.column_int(2);
                const key = std.fmt.allocPrint(self.alloc, "{s}\x00{d}\x00{d}", .{ dp, dl, dc }) catch null;
                const dup = if (key) |k| (seen_loc.contains(k)) else true;
                if (key) |k| self.alloc.free(k);
                if (!dup) {
                    const dc_client = self.toClientColFromPath(&frc_ref, dp, dl - 1, dc);
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeLoc(w, dp, dl - 1, dc_client, dc_client + @as(u32, @intCast(word.len)));
                }
            }
        }
    } else if (is_local_ref) {
        if (ref_scope_id) |sid| {
            // Scoped: emit local_var writes + scoped refs for this scope only
            const lv_stmt = try self.cachedStmt(
                \\SELECT f.path, lv.line, lv.col FROM local_vars lv JOIN files f ON lv.file_id=f.id
                \\WHERE lv.name=? AND lv.scope_id=?
            );
            defer lv_stmt.reset();
            lv_stmt.bind_text(1, word);
            lv_stmt.bind_int(2, sid);
            var lv_i: usize = 0;
            while (try lv_stmt.step()) {
                lv_i += 1;
                if ((lv_i & 0xFF) == 0 and self.isCancelled(msg.id)) {
                    aw.deinit();
                    return self.cancelledResponse(msg.id);
                }
                if (!first) try w.writeByte(',');
                first = false;
                const rp = lv_stmt.column_text(0);
                const rl = lv_stmt.column_int(1);
                const rc = lv_stmt.column_int(2);
                const rc_client = self.toClientColFromPath(&frc_ref, rp, rl - 1, rc);
                try writeLoc(w, rp, rl - 1, rc_client, rc_client + @as(u32, @intCast(word.len)));
            }
            const scoped_ref = try self.cachedStmt(
                \\SELECT f.path, r.line, r.col FROM refs r JOIN files f ON r.file_id=f.id
                \\WHERE r.name=? AND r.scope_id=?
            );
            defer scoped_ref.reset();
            scoped_ref.bind_text(1, word);
            scoped_ref.bind_int(2, sid);
            var sr_i: usize = 0;
            while (try scoped_ref.step()) {
                sr_i += 1;
                if ((sr_i & 0xFF) == 0 and self.isCancelled(msg.id)) {
                    aw.deinit();
                    return self.cancelledResponse(msg.id);
                }
                if (!first) try w.writeByte(',');
                first = false;
                const rp = scoped_ref.column_text(0);
                const rl = scoped_ref.column_int(1);
                const rc = scoped_ref.column_int(2);
                const rc_client = self.toClientColFromPath(&frc_ref, rp, rl - 1, rc);
                try writeLoc(w, rp, rl - 1, rc_client, rc_client + @as(u32, @intCast(word.len)));
            }
        }
        // else top-level local — no cross-file refs, return empty
    } else {
        // Global: all refs across all files. When includeDeclaration=false, exclude
        // ref rows that coincide with a definition site (the visitor over-inserts
        // when a class/module name is walked as a NODE_CONSTANT child).
        const stmt = if (include_decl)
            try self.cachedStmt(
                \\SELECT f.path, r.line, r.col
                \\FROM refs r JOIN files f ON r.file_id = f.id
                \\WHERE r.name = ?
            )
        else
            try self.cachedStmt(
                \\SELECT f.path, r.line, r.col
                \\FROM refs r JOIN files f ON r.file_id = f.id
                \\WHERE r.name = ?
                \\AND NOT EXISTS (
                \\  SELECT 1 FROM symbols s
                \\  WHERE s.file_id = r.file_id
                \\    AND s.name = r.name
                \\    AND s.line = r.line
                \\    AND (s.col = r.col OR s.kind IN ('class','module'))
                \\)
            );
        defer stmt.reset();
        stmt.bind_text(1, word);
        var gref_i: usize = 0;
        while (try stmt.step()) {
            gref_i += 1;
            if ((gref_i & 0xFF) == 0 and self.isCancelled(msg.id)) {
                aw.deinit();
                return self.cancelledResponse(msg.id);
            }
            if (!first) try w.writeByte(',');
            first = false;
            const ref_path = stmt.column_text(0);
            const ref_line = stmt.column_int(1);
            const ref_col = stmt.column_int(2);
            const ref_col_client = self.toClientColFromPath(&frc_ref, ref_path, ref_line - 1, ref_col);
            try writeLoc(w, ref_path, ref_line - 1, ref_col_client, ref_col_client + @as(u32, @intCast(word.len)));
        }

        // includeDeclaration=true: also emit the declaration site(s) from the
        // symbols table. The refs visitor over-inserts a ref at class/module name
        // nodes (so those decls already appear above), but method and constant
        // declarations live only in `symbols`; without this they were silently
        // dropped despite the LSP spec requiring the declaration when true.
        if (include_decl) {
            const decl_stmt = try self.cachedStmt(
                \\SELECT f.path, s.line, s.col
                \\FROM symbols s JOIN files f ON s.file_id = f.id
                \\WHERE s.name = ?
                \\  AND f.is_gem = 0
                \\  AND s.kind IN ('def','constant','class','module','classdef')
                \\  AND NOT EXISTS (
                \\    SELECT 1 FROM refs r
                \\    WHERE r.file_id = s.file_id AND r.name = s.name AND r.line = s.line
                \\  )
            );
            defer decl_stmt.reset();
            decl_stmt.bind_text(1, word);
            var decl_i: usize = 0;
            while (try decl_stmt.step()) {
                decl_i += 1;
                if ((decl_i & 0xFF) == 0 and self.isCancelled(msg.id)) {
                    aw.deinit();
                    return self.cancelledResponse(msg.id);
                }
                if (!first) try w.writeByte(',');
                first = false;
                const dp = decl_stmt.column_text(0);
                const dl = decl_stmt.column_int(1);
                const dc = decl_stmt.column_int(2);
                const dc_client = self.toClientColFromPath(&frc_ref, dp, dl - 1, dc);
                try writeLoc(w, dp, dl - 1, dc_client, dc_client + @as(u32, @intCast(word.len)));
            }
        }
    }
    try w.writeByte(']');

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}
