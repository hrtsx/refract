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

pub fn handleDefinition(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    // Background flush worker drains dirty URIs; query path stays read-only.
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    const rtx = self.beginRead();
    defer rtx.end();
    const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
    const pos = extractPosition(msg.params) orelse return emptyResult(msg);
    const line: u32 = pos.line;
    const character: u32 = pos.character;

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch
        return emptyResult(msg);
    defer self.alloc.free(source);

    const offset = self.clientPosToOffset(source, line, character);

    if (std.mem.endsWith(u8, path, ".erb") and !erb_mapping.isErbRubyContext(source, offset))
        return emptyResult(msg);

    if (resolveRequireTarget(self.alloc, self.queryDb(), source, offset, path)) |target_path| {
        defer self.alloc.free(target_path);
        const target_uri = pathToUri(self.alloc, target_path) catch return emptyResult(msg);
        defer self.alloc.free(target_uri);
        var req_aw = std.Io.Writer.Allocating.init(self.alloc);
        const rw = &req_aw.writer;
        if (self.client_caps_def_link) {
            // Scan for the enclosing quote characters to build originSelectionRange
            var qs = offset;
            while (qs > 0 and source[qs - 1] != '"' and source[qs - 1] != '\'' and source[qs - 1] != '\n') qs -= 1;
            if (qs > 0) qs -= 1; // include the opening quote
            var qe = offset;
            while (qe < source.len and source[qe] != '"' and source[qe] != '\'' and source[qe] != '\n') qe += 1;
            if (qe < source.len and (source[qe] == '"' or source[qe] == '\'')) qe += 1; // include closing quote
            const origin_sc = self.offsetToClientChar(source, qs, line);
            const origin_ec = self.offsetToClientChar(source, qe, line);
            try rw.print(
                "[{{\"targetUri\":\"{s}\",\"targetRange\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"targetSelectionRange\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}]",
                .{ target_uri, line, origin_sc, line, origin_ec },
            );
        } else {
            try rw.print("[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}}}}]", .{target_uri});
        }
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try req_aw.toOwnedSlice(), .@"error" = null };
    }

    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    // Compute origin selection range for LocationLink support
    const word_start_offset = @intFromPtr(word.ptr) - @intFromPtr(source.ptr);
    const origin_char = self.offsetToClientChar(source, word_start_offset, line);
    const origin_end_char = self.offsetToClientChar(source, word_start_offset + word.len, line);
    const def_origin = DefOrigin{ .line = line, .start_char = origin_char, .end_char = origin_end_char };

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var found_any = false;
    var frc_def: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_def.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_def.deinit(self.alloc);
    }

    // Receiver-aware definition: when the cursor is on a method called on a
    // literal receiver (`[1,2,3].first`, `"x".upcase`, `42.to_s`, …) or a
    // capitalized constant receiver, prefer the canonical class-scoped match
    // before falling through to unscoped name lookup.
    if (word_start_offset > 0 and source[word_start_offset - 1] == '.') {
        var recv_type: ?[]const u8 = null;
        if (literal_receiver.extractLiteralReceiver(source, word_start_offset - 1)) |lit| {
            recv_type = literal_receiver.classifyLiteralType(lit);
        }
        if (recv_type == null) {
            const recv_off = if (word_start_offset >= 2) word_start_offset - 2 else 0;
            const recv_w = extractWord(source, recv_off);
            if (recv_w.len > 0 and std.ascii.isUpper(recv_w[0])) recv_type = recv_w;
        }
        // Local-var receiver: `u = User.new; u.method` — resolve the receiver's
        // inferred type from local_vars so receiver-scoped definition lookup can
        // find class methods (incl. synthesized delegate/attachment defs). Hover
        // already does this; navigation must match.
        var localvar_recv_owned: ?[]u8 = null;
        defer if (localvar_recv_owned) |b| self.alloc.free(b);
        if (recv_type == null) {
            const recv_off = if (word_start_offset >= 2) word_start_offset - 2 else 0;
            const recv_w = extractWord(source, recv_off);
            if (recv_w.len > 0 and !std.ascii.isUpper(recv_w[0])) {
                const cursor_line: i64 = @intCast(line + 1);
                const fstmt = self.cachedStmt("SELECT id FROM files WHERE path = ?") catch null;
                if (fstmt) |fs| {
                    defer fs.reset();
                    fs.bind_text(1, path);
                    if ((fs.step() catch false)) {
                        const fid = fs.column_int(0);
                        const lv = self.cachedStmt("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1") catch null;
                        if (lv) |lvs| {
                            defer lvs.reset();
                            lvs.bind_int(1, fid);
                            lvs.bind_text(2, recv_w);
                            lvs.bind_int(3, cursor_line);
                            if ((lvs.step() catch false)) {
                                const t = lvs.column_text(0);
                                if (t.len > 0) {
                                    localvar_recv_owned = self.alloc.dupe(u8, t) catch null;
                                    if (localvar_recv_owned) |b| recv_type = b;
                                }
                            }
                        }
                    }
                }
            }
        }
        // Sorbet/Steep receiver fallback: when no literal/constant detected,
        // ask the type bridge for the receiver word's class.
        var sorbet_recv_owned: ?[]u8 = null;
        defer if (sorbet_recv_owned) |b| self.alloc.free(b);
        if (recv_type == null) {
            const recv_off = if (word_start_offset >= 2) word_start_offset - 2 else 0;
            const recv_w = extractWord(source, recv_off);
            if (recv_w.len > 0) {
                if (type_resolver.resolve(self.alloc, self.queryDb(), recv_w, null, -1)) |hit_const| {
                    var hit = hit_const;
                    defer hit.deinit(self.alloc);
                    if (hit.confidence >= self.type_checker_confidence.surface) {
                        sorbet_recv_owned = type_resolver.stripWrapper(self.alloc, hit.type_str) catch null;
                        if (sorbet_recv_owned) |b| recv_type = b;
                    }
                }
            }
        }
        if (recv_type) |rt| {
            try emitDefinitionOnClass(self, w, word, rt, &found_any, &frc_def, def_origin);
        }
    }

    // Resolve a same-file, in-scope local variable BEFORE the global symbol
    // table. A local (incl. pattern-match bindings) shadows a same-named global
    // def — without this, `x` used in a method resolves to an unrelated class's
    // `x` method in another file instead of the local binding.
    if (!found_any) {
        const cursor_line: i64 = @intCast(line + 1);

        var def_word_start: usize = offset;
        while (def_word_start > 0 and isRubyIdent(source[def_word_start - 1])) def_word_start -= 1;
        var def_line_start: usize = 0;
        var dj: usize = 0;
        while (dj < def_word_start) : (dj += 1) {
            if (source[dj] == '\n') def_line_start = dj + 1;
        }
        const def_col_0: i64 = @intCast(def_word_start - def_line_start);

        const f_stmt = try self.cachedStmt("SELECT id FROM files WHERE path = ?");
        defer f_stmt.reset();
        f_stmt.bind_text(1, path);
        if (try f_stmt.step()) {
            const fid = f_stmt.column_int(0);
            const scope_opt = editing.resolveScopeId(self, fid, word, cursor_line, def_col_0);
            const lv_stmt = if (scope_opt) |sid| blk: {
                if (sid != 0) {
                    const s = try self.cachedStmt(
                        \\SELECT name, line, col FROM local_vars
                        \\WHERE file_id=? AND name=? AND scope_id=?
                        \\ORDER BY line DESC LIMIT 1
                    );
                    s.bind_int(1, fid);
                    s.bind_text(2, word);
                    s.bind_int(3, sid);
                    break :blk s;
                } else {
                    const s = try self.cachedStmt(
                        \\SELECT name, line, col FROM local_vars
                        \\WHERE file_id=? AND name=? AND scope_id IS NULL
                        \\ORDER BY line DESC LIMIT 1
                    );
                    s.bind_int(1, fid);
                    s.bind_text(2, word);
                    break :blk s;
                }
            } else blk: {
                const s = try self.cachedStmt(
                    \\SELECT name, line, col FROM local_vars
                    \\WHERE file_id = ? AND name = ? AND line <= ?
                    \\ORDER BY line DESC LIMIT 1
                );
                s.bind_int(1, fid);
                s.bind_text(2, word);
                s.bind_int(3, cursor_line);
                break :blk s;
            };
            defer lv_stmt.reset();
            if (try lv_stmt.step()) {
                const lv_name = lv_stmt.column_text(0);
                const lv_line = lv_stmt.column_int(1);
                const lv_col = lv_stmt.column_int(2);
                const lv_line_src = getLineSlice(source, @intCast(lv_line - 1));
                const lv_start = self.toClientCol(lv_line_src, @intCast(lv_col));
                if (found_any) try w.writeByte(',');
                found_any = true;
                try writeLoc(w, path, lv_line - 1, lv_start, lv_start + @as(u32, @intCast(lv_name.len)));
            }
        }
    }

    // Binding-exact precedence for constants: if the cursor token is a constant whose
    // ref resolved to one definition at index time (refs.def_id, nesting-aware), jump
    // straight there. Avoids the name-global path wrong-jumping to a same-named
    // constant in another namespace. Bare names only (qualified paths store their full
    // name in refs.name, so `word` won't match → harmless fall-through).
    if (!found_any and word.len > 0 and word[0] >= 'A' and word[0] <= 'Z') {
        const cursor_line_1based: i64 = @intCast(line + 1);
        const fstmt = self.cachedStmt("SELECT id FROM files WHERE path = ?") catch null;
        if (fstmt) |fs| {
            defer fs.reset();
            fs.bind_text(1, path);
            if ((fs.step() catch false)) {
                const fid = fs.column_int(0);
                const dq = self.cachedStmt("SELECT def_id FROM refs WHERE file_id=? AND name=? AND line=? AND def_id IS NOT NULL LIMIT 1") catch null;
                if (dq) |d| {
                    defer d.reset();
                    d.bind_int(1, fid);
                    d.bind_text(2, word);
                    d.bind_int(3, cursor_line_1based);
                    if ((d.step() catch false)) {
                        const did = d.column_int(0);
                        const ds = self.cachedStmt(
                            \\SELECT s.name, s.line, s.col, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE s.id=?
                        ) catch null;
                        if (ds) |dsr| {
                            defer dsr.reset();
                            dsr.bind_int(1, did);
                            if ((dsr.step() catch false)) {
                                const sym_name = dsr.column_text(0);
                                const sym_line = dsr.column_int(1);
                                const sym_col = dsr.column_int(2);
                                const sym_path = dsr.column_text(3);
                                const start_char = self.toClientColFromPath(&frc_def, sym_path, sym_line - 1, sym_col);
                                if (found_any) try w.writeByte(',');
                                found_any = true;
                                if (self.client_caps_def_link) {
                                    try w.writeAll("{\"targetUri\":\"file://");
                                    try writePathAsUri(w, sym_path);
                                    try w.print("\",\"targetRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                                        sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
                                    });
                                    try w.print(",\"targetSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                                        sym_line - 1, start_char, sym_line - 1, start_char + @as(u32, @intCast(sym_name.len)),
                                    });
                                    try w.print(",\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
                                        def_origin.line, def_origin.start_char, def_origin.line, def_origin.end_char,
                                    });
                                    try w.writeByte('}');
                                } else {
                                    try writeLoc(w, sym_path, sym_line - 1, start_char, start_char + @as(u32, @intCast(sym_name.len)));
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (!found_any) {
        try queryAndEmitDefinitions(self, w, word, &found_any, &frc_def, def_origin, path);
    }

    if (!found_any) {
        const qualified = extractQualifiedName(source, offset);
        if (!std.mem.eql(u8, qualified, word)) {
            try queryAndEmitDefinitions(self, w, qualified, &found_any, &frc_def, def_origin, path);
        }
    }

    // Route-helper go-to-def: `foo_path` / `foo_url` → the route declaration line.
    // Only as a fallback (the array is still empty here), so a real `def foo_path`
    // would have won above.
    if (!found_any and (std.mem.endsWith(u8, word, "_path") or std.mem.endsWith(u8, word, "_url"))) {
        const suffix_len: usize = if (std.mem.endsWith(u8, word, "_path")) 5 else 4;
        if (word.len > suffix_len) {
            const helper = word[0 .. word.len - suffix_len];
            if (self.cachedStmt(
                \\SELECT DISTINCT f.path, r.line, r.col FROM routes r JOIN files f ON r.file_id=f.id
                \\WHERE r.helper_name = ? LIMIT 5
            )) |rs| {
                defer rs.reset();
                rs.bind_text(1, helper);
                while (rs.step() catch false) {
                    const rp = rs.column_text(0);
                    const rl = rs.column_int(1);
                    const rc = rs.column_int(2);
                    const sc = self.toClientColFromPath(&frc_def, rp, rl - 1, rc);
                    if (found_any) try w.writeByte(',');
                    found_any = true;
                    if (self.client_caps_def_link) {
                        try w.writeAll("{\"targetUri\":\"file://");
                        try writePathAsUri(w, rp);
                        try w.print("\",\"targetRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{ rl - 1, sc, rl - 1, sc });
                        try w.print(",\"targetSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{ rl - 1, sc, rl - 1, sc });
                        try w.print(",\"originSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{ def_origin.line, def_origin.start_char, def_origin.line, def_origin.end_char });
                        try w.writeByte('}');
                    } else {
                        try writeLoc(w, rp, rl - 1, sc, sc);
                    }
                }
            } else |_| {}
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
