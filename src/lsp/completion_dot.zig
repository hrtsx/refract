const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const erb_mapping = @import("erb_mapping.zig");
const indexer = @import("../indexer/index.zig");
const snippets = @import("snippets.zig");
const hot_index_mod = @import("hot_index.zig");
const llm_adapter = @import("llm_adapter.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractPosition = S.extractPosition;
const uriToPath = S.uriToPath;
const emptyResult = S.emptyResult;
const writeEscapedJsonContent = S.writeEscapedJsonContent;
const writeEscapedJson = S.writeEscapedJson;
const resolveRequireTarget = S.resolveRequireTarget;
const getLineSlice = S.getLineSlice;
const extractWord = S.extractWord;
const extractQualifiedName = S.extractQualifiedName;
const extractBaseClass = S.extractBaseClass;
const extractGenericElement = S.extractGenericElement;
const utf8ColToUtf16 = S.utf8ColToUtf16;
const isInStringOrComment = S.isInStringOrComment;
const isRubyIdent = S.isRubyIdent;
const isValidRubyIdent = S.isValidRubyIdent;
const frcGet = S.frcGet;
const writePathAsUri = S.writePathAsUri;
const matchesCamelInitials = S.matchesCamelInitials;
const isSubsequence = S.isSubsequence;
const buildQueryPattern = S.buildQueryPattern;
const buildPrefixPattern = S.buildPrefixPattern;

const c_common = @import("completion_common.zig");
const writeInsertTextSnippet = c_common.writeInsertTextSnippet;
const addStdlibCompletions = c_common.addStdlibCompletions;

fn hotCrossFileReturnType(self: *Server, method_name: []const u8, parent_class: []const u8) ?[]u8 {
    if (!self.hot_index_enabled.load(.monotonic)) return null;
    self.hot_mu.lockUncancelable(std.Options.debug_io);
    defer self.hot_mu.unlock(std.Options.debug_io);
    const hot = self.hot.load(.acquire) orelse return null;
    for (hot.lookupName(method_name)) |sym| {
        if (sym.kind != .def) continue;
        const ret = sym.return_type orelse continue;
        if (sym.parent_name) |p| {
            if (std.mem.eql(u8, p, parent_class)) return self.alloc.dupe(u8, ret) catch null;
            continue;
        }
        for (hot.classesIn(sym.file_id)) |cls_name| {
            if (std.mem.eql(u8, cls_name, parent_class)) return self.alloc.dupe(u8, ret) catch null;
        }
    }
    return null;
}

pub fn completeDot(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, character: u32, offset: usize, word: []const u8) !?types.ResponseMessage {
    _ = word;
    var recv_offset = if (offset >= 2) offset - 2 else 0;
    while (recv_offset > 0 and (source[recv_offset] == ' ' or source[recv_offset] == '\t')) : (recv_offset -= 1) {}
    var recv_word = extractQualifiedName(source, recv_offset);
    if (recv_word.len == 0 and recv_offset > 0 and source[recv_offset] == '&') {
        recv_offset = if (recv_offset >= 1) recv_offset - 1 else 0;
        recv_word = extractQualifiedName(source, recv_offset);
    }
    if (recv_word.len == 0) return null;
    {
        const fdc_stmt = try self.cachedStmt("SELECT id FROM files WHERE path = ?");
        defer fdc_stmt.reset();
        fdc_stmt.bind_text(1, path);
        if (try fdc_stmt.step()) {
            const fdc_id = fdc_stmt.column_int(0);
            const cursor_line_db: i64 = @intCast(line + 1);
            const th_stmt = try self.cachedStmt("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1");
            defer th_stmt.reset();
            th_stmt.bind_int(1, fdc_id);
            th_stmt.bind_text(2, recv_word);
            th_stmt.bind_int(3, cursor_line_db);
            const th_hit = try th_stmt.step();
            var chain_class_buf: ?[]u8 = null;
            defer if (chain_class_buf) |b| self.alloc.free(b);
            if (!th_hit) {
                var rv_start: usize = if (recv_offset < source.len and !isRubyIdent(source[recv_offset])) recv_offset else recv_offset + 1;
                while (rv_start > 0 and isRubyIdent(source[rv_start - 1])) rv_start -= 1;
                if (rv_start >= 2 and source[rv_start - 1] == '.') {
                    var outer_offset = rv_start - 2;
                    if (outer_offset >= 1 and source[outer_offset] == '&') outer_offset -= 1;
                    const outer_word = extractQualifiedName(source, outer_offset);
                    // `Const.new` → an instance of Const (constructor inference).
                    if (std.mem.eql(u8, recv_word, "new") and outer_word.len > 0 and std.ascii.isUpper(outer_word[0])) {
                        chain_class_buf = try self.alloc.dupe(u8, outer_word);
                    }
                    if (chain_class_buf == null and outer_word.len > 0) {
                        const oth_stmt = try self.cachedStmt("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1");
                        defer oth_stmt.reset();
                        oth_stmt.bind_int(1, fdc_id);
                        oth_stmt.bind_text(2, outer_word);
                        oth_stmt.bind_int(3, cursor_line_db);
                        if (try oth_stmt.step()) {
                            const outer_type = oth_stmt.column_text(0);
                            if (outer_type.len > 0) {
                                const resolved_outer = extractBaseClass(outer_type);
                                if (hotCrossFileReturnType(self, recv_word, resolved_outer)) |rt| {
                                    chain_class_buf = rt;
                                } else {
                                    const ret_stmt = try self.cachedStmt("SELECT return_type FROM symbols WHERE name=?1 AND kind='def' AND return_type IS NOT NULL AND (parent_name=?2 OR (parent_name IS NULL AND file_id IN (SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?2))) LIMIT 1");
                                    defer ret_stmt.reset();
                                    ret_stmt.bind_text(1, recv_word);
                                    ret_stmt.bind_text(2, resolved_outer);
                                    if (try ret_stmt.step()) {
                                        const cc = ret_stmt.column_text(0);
                                        if (cc.len > 0) chain_class_buf = try self.alloc.dupe(u8, cc);
                                    }
                                }
                                if (chain_class_buf == null) {
                                    if (indexer.lookupStdlibReturn(resolved_outer, recv_word)) |rt| {
                                        chain_class_buf = try self.alloc.dupe(u8, rt);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (chain_class_buf == null and recv_word.len > 0 and recv_word[0] == '@') {
                const ivar_name = recv_word[1..];
                const enclosing_class_stmt = try self.cachedStmt("SELECT id FROM symbols WHERE file_id=? AND kind IN ('class','module') AND line<=? ORDER BY line DESC LIMIT 1");
                defer enclosing_class_stmt.reset();
                enclosing_class_stmt.bind_int(1, fdc_id);
                enclosing_class_stmt.bind_int(2, cursor_line_db);
                if (try enclosing_class_stmt.step()) {
                    const class_id = enclosing_class_stmt.column_int(0);
                    const ivar_stmt = try self.cachedStmt("SELECT type_hint FROM local_vars WHERE class_id=? AND name=? AND type_hint IS NOT NULL LIMIT 1");
                    defer ivar_stmt.reset();
                    ivar_stmt.bind_int(1, class_id);
                    ivar_stmt.bind_text(2, ivar_name);
                    if (try ivar_stmt.step()) {
                        const ivar_type = ivar_stmt.column_text(0);
                        if (ivar_type.len > 0) chain_class_buf = try self.alloc.dupe(u8, ivar_type);
                    }
                }
            }

            if (chain_class_buf == null and std.mem.eql(u8, recv_word, "self")) {
                const sc_stmt = try self.cachedStmt("SELECT name FROM symbols WHERE file_id=? AND kind IN ('class','module') AND line<=? ORDER BY line DESC LIMIT 1");
                defer sc_stmt.reset();
                sc_stmt.bind_int(1, fdc_id);
                sc_stmt.bind_int(2, cursor_line_db);
                if (try sc_stmt.step()) {
                    const sc = sc_stmt.column_text(0);
                    if (sc.len > 0) chain_class_buf = try self.alloc.dupe(u8, sc);
                }
            }
            const is_constant_recv = recv_word.len > 0 and std.ascii.isUpper(recv_word[0]);
            if (chain_class_buf == null and is_constant_recv) {
                // Resolve an unqualified/relative constant (e.g. `CustomerReturn`)
                // to its stored fully-qualified name (`Spree::CustomerReturn`):
                // parent_name is stored qualified, so a bare receiver otherwise
                // matches no members. Prefer an exact name, else the shortest
                // `%::Name` suffix match.
                if (std.mem.indexOf(u8, recv_word, "::") == null) {
                    const qstmt = try self.cachedStmt(
                        \\SELECT name FROM symbols WHERE kind IN ('class','module')
                        \\  AND (name = ?1 OR name LIKE '%::' || ?1)
                        \\ORDER BY CASE WHEN name = ?1 THEN 0 ELSE 1 END, length(name) LIMIT 1
                    );
                    defer qstmt.reset();
                    qstmt.bind_text(1, recv_word);
                    if (try qstmt.step()) {
                        const qn = qstmt.column_text(0);
                        if (qn.len > 0) chain_class_buf = try self.alloc.dupe(u8, qn);
                    }
                }
                if (chain_class_buf == null) chain_class_buf = try self.alloc.dupe(u8, recv_word);
            }
            const is_self_recv = std.mem.eql(u8, recv_word, "self");
            const class_name_raw: []const u8 = if (th_hit) th_stmt.column_text(0) else if (chain_class_buf) |cc| cc else "";
            const class_name = extractBaseClass(class_name_raw);
            if (class_name.len > 0) {
                var mro_arena = std.heap.ArenaAllocator.init(self.alloc);
                defer mro_arena.deinit();
                const ma = mro_arena.allocator();

                var aw_dot = std.Io.Writer.Allocating.init(self.alloc);
                const wd = &aw_dot.writer;
                try wd.writeAll("{\"isIncomplete\":false,\"items\":[");
                var first_dot = true;
                var seen_names = std.StringHashMap(void).init(ma);
                var seen_classes = std.StringHashMap(void).init(ma);

                // Handle union types: "String | Integer" → query each component
                var union_it = std.mem.splitSequence(u8, class_name, " | ");
                var union_first = true;
                while (union_it.next()) |union_part| {
                    const part_trimmed = std.mem.trim(u8, union_part, " \t");
                    if (part_trimmed.len == 0) continue;
                    const resolved_class = extractBaseClass(part_trimmed);
                    if (resolved_class.len == 0) continue;
                    if (!union_first) {
                        seen_classes.clearRetainingCapacity();
                    }
                    union_first = false;

                    var current = try ma.dupe(u8, resolved_class);
                    const own_stmt_hoisted = if (is_self_recv)
                        self.cachedStmt(
                            \\SELECT s.name, s.doc,
                            \\  (SELECT GROUP_CONCAT(
                            \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
                            \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
                            \\    ELSE p.name END, ', ')
                            \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position),
                            \\  s.return_type,
                            \\  (SELECT GROUP_CONCAT(
                            \\    CASE p.kind WHEN 'keyword' THEN p.name||': '||COALESCE(p.type_hint,'?')
                            \\    WHEN 'rest' THEN '*'||p.name||': '||COALESCE(p.type_hint,'?')
                            \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
                            \\    ELSE p.name||': '||COALESCE(p.type_hint,'?') END, ', ')
                            \\   FROM params p WHERE p.symbol_id=s.id AND p.type_hint IS NOT NULL ORDER BY p.position)
                            \\FROM symbols s
                            \\WHERE s.kind='def' AND (s.parent_name = ?1 OR (s.parent_name IS NULL AND s.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?2
                            \\)))
                        ) catch null
                    else
                        self.cachedStmt(
                            \\SELECT s.name, s.doc,
                            \\  (SELECT GROUP_CONCAT(
                            \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
                            \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
                            \\    ELSE p.name END, ', ')
                            \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position),
                            \\  s.return_type,
                            \\  (SELECT GROUP_CONCAT(
                            \\    CASE p.kind WHEN 'keyword' THEN p.name||': '||COALESCE(p.type_hint,'?')
                            \\    WHEN 'rest' THEN '*'||p.name||': '||COALESCE(p.type_hint,'?')
                            \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
                            \\    ELSE p.name||': '||COALESCE(p.type_hint,'?') END, ', ')
                            \\   FROM params p WHERE p.symbol_id=s.id AND p.type_hint IS NOT NULL ORDER BY p.position)
                            \\FROM symbols s
                            \\WHERE s.kind='def' AND (s.parent_name = ?1 OR (s.parent_name IS NULL AND s.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?2
                            \\))) AND (s.visibility IS NULL OR s.visibility = 'public')
                        ) catch null;
                    defer if (own_stmt_hoisted) |s2| s2.reset();
                    const cls_stmt_hoisted = if (is_constant_recv)
                        self.cachedStmt(
                            \\SELECT s.name, s.doc FROM symbols s
                            \\WHERE s.kind='classdef' AND (s.parent_name = ?1 OR (s.parent_name IS NULL AND s.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?2
                            \\))) AND (s.visibility IS NULL OR s.visibility = 'public')
                        ) catch null
                    else
                        null;
                    defer if (cls_stmt_hoisted) |s2| s2.reset();
                    var depth: u8 = 0;
                    while (depth < 8) : (depth += 1) {
                        if (seen_classes.contains(current)) break;
                        try seen_classes.put(try ma.dupe(u8, current), {});

                        const prep_stmt = try self.cachedStmt(
                            \\SELECT DISTINCT s2.name, s2.doc FROM symbols s2
                            \\JOIN mixins m ON s2.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=m.module_name
                            \\)
                            \\WHERE m.class_id IN (
                            \\  SELECT id FROM symbols WHERE kind IN ('class','module') AND name=?
                            \\) AND s2.kind='def' AND m.kind='prepend'
                        );
                        defer prep_stmt.reset();
                        prep_stmt.bind_text(1, current);
                        while (try prep_stmt.step()) {
                            const mname2 = prep_stmt.column_text(0);
                            if (seen_names.contains(mname2)) continue;
                            try seen_names.put(try ma.dupe(u8, mname2), {});
                            if (!first_dot) try wd.writeByte(',');
                            first_dot = false;
                            const mdoc = prep_stmt.column_text(1);
                            try wd.writeAll("{\"label\":");
                            try writeEscapedJson(wd, mname2);
                            try wd.writeAll(",\"kind\":3,\"detail\":\"(def)\",\"sortText\":\"0_");
                            try writeEscapedJsonContent(wd, mname2);
                            try wd.writeAll("\",\"filterText\":\"");
                            try writeEscapedJsonContent(wd, mname2);
                            try wd.writeAll("\",\"commitCharacters\":[\"(\"]");
                            if (mdoc.len > 0) {
                                try wd.writeAll(",\"documentation\":\"");
                                try writeEscapedJsonContent(wd, mdoc);
                                try wd.writeByte('"');
                            }
                            try wd.writeAll(",\"textEdit\":{\"range\":{\"start\":{\"line\":");
                            try wd.print("{d}", .{line});
                            try wd.writeAll(",\"character\":");
                            try wd.print("{d}", .{character});
                            try wd.writeAll("},\"end\":{\"line\":");
                            try wd.print("{d}", .{line});
                            try wd.writeAll(",\"character\":");
                            try wd.print("{d}", .{character});
                            try wd.writeAll("}},\"newText\":\"");
                            try writeEscapedJsonContent(wd, mname2);
                            try wd.writeAll("\"},\"data\":{\"name\":");
                            try writeEscapedJson(wd, mname2);
                            try wd.writeAll("}");
                            try wd.writeByte('}');
                        }

                        const own_stmt = own_stmt_hoisted orelse continue;
                        own_stmt.reset();
                        own_stmt.bind_text(1, current);
                        own_stmt.bind_text(2, current);
                        while (try own_stmt.step()) {
                            const mname2 = own_stmt.column_text(0);
                            if (seen_names.contains(mname2)) continue;
                            try seen_names.put(try ma.dupe(u8, mname2), {});
                            if (!first_dot) try wd.writeByte(',');
                            first_dot = false;
                            const mdoc = own_stmt.column_text(1);
                            const msig = own_stmt.column_text(2);
                            const mrt = own_stmt.column_text(3);
                            const mtyped_sig = own_stmt.column_text(4); // typed param sig (may be empty)
                            try wd.writeAll("{\"label\":");
                            try writeEscapedJson(wd, mname2);
                            // detail: "(typed_param: Type, ...) → ReturnType" when type info available
                            if (mtyped_sig.len > 0 or mrt.len > 0) {
                                try wd.writeAll(",\"kind\":3,\"detail\":\"(");
                                if (mtyped_sig.len > 0) {
                                    try writeEscapedJsonContent(wd, mtyped_sig);
                                }
                                try wd.writeAll(")");
                                if (mrt.len > 0) {
                                    try wd.writeAll(" \u{2192} ");
                                    try writeEscapedJsonContent(wd, mrt);
                                }
                                try wd.writeAll("\",\"sortText\":\"0_");
                            } else {
                                try wd.writeAll(",\"kind\":3,\"detail\":\"(def)\",\"sortText\":\"0_");
                            }
                            try writeEscapedJsonContent(wd, mname2);
                            try wd.writeAll("\",\"filterText\":\"");
                            try writeEscapedJsonContent(wd, mname2);
                            try wd.writeAll("\",\"commitCharacters\":[\"(\"]");
                            if (msig.len > 0) writeInsertTextSnippet(wd, mname2, msig) catch {}; // response building
                            if (mdoc.len > 0) {
                                try wd.writeAll(",\"documentation\":\"");
                                try writeEscapedJsonContent(wd, mdoc);
                                try wd.writeByte('"');
                            }
                            try wd.writeAll(",\"textEdit\":{\"range\":{\"start\":{\"line\":");
                            try wd.print("{d}", .{line});
                            try wd.writeAll(",\"character\":");
                            try wd.print("{d}", .{character});
                            try wd.writeAll("},\"end\":{\"line\":");
                            try wd.print("{d}", .{line});
                            try wd.writeAll(",\"character\":");
                            try wd.print("{d}", .{character});
                            try wd.writeAll("}},\"newText\":\"");
                            try writeEscapedJsonContent(wd, mname2);
                            try wd.writeAll("\"},\"data\":{\"name\":");
                            try writeEscapedJson(wd, mname2);
                            try wd.writeAll("}");
                            try wd.writeByte('}');
                        }

                        if (is_constant_recv) {
                            if (cls_stmt_hoisted) |cls_stmt| {
                                cls_stmt.reset();
                                cls_stmt.bind_text(1, current);
                                cls_stmt.bind_text(2, current);
                                while (try cls_stmt.step()) {
                                    const mname2 = cls_stmt.column_text(0);
                                    if (seen_names.contains(mname2)) continue;
                                    try seen_names.put(try ma.dupe(u8, mname2), {});
                                    if (!first_dot) try wd.writeByte(',');
                                    first_dot = false;
                                    const mdoc = cls_stmt.column_text(1);
                                    try wd.writeAll("{\"label\":");
                                    try writeEscapedJson(wd, mname2);
                                    try wd.writeAll(",\"kind\":3,\"detail\":\"(def self)\",\"sortText\":\"0_");
                                    try writeEscapedJsonContent(wd, mname2);
                                    try wd.writeAll("\",\"filterText\":\"");
                                    try writeEscapedJsonContent(wd, mname2);
                                    try wd.writeAll("\",\"commitCharacters\":[\"(\"]");
                                    if (mdoc.len > 0) {
                                        try wd.writeAll(",\"documentation\":\"");
                                        try writeEscapedJsonContent(wd, mdoc);
                                        try wd.writeByte('"');
                                    }
                                    try wd.writeAll(",\"textEdit\":{\"range\":{\"start\":{\"line\":");
                                    try wd.print("{d}", .{line});
                                    try wd.writeAll(",\"character\":");
                                    try wd.print("{d}", .{character});
                                    try wd.writeAll("},\"end\":{\"line\":");
                                    try wd.print("{d}", .{line});
                                    try wd.writeAll(",\"character\":");
                                    try wd.print("{d}", .{character});
                                    try wd.writeAll("}},\"newText\":\"");
                                    try writeEscapedJsonContent(wd, mname2);
                                    try wd.writeAll("\"},\"data\":{\"name\":");
                                    try writeEscapedJson(wd, mname2);
                                    try wd.writeAll("}");
                                    try wd.writeByte('}');
                                }
                            }
                        }

                        const mix_stmt = try self.cachedStmt(
                            \\SELECT DISTINCT s2.name, s2.doc FROM symbols s2
                            \\JOIN mixins m ON s2.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=m.module_name
                            \\)
                            \\WHERE m.class_id IN (
                            \\  SELECT id FROM symbols WHERE kind IN ('class','module') AND name=?
                            \\) AND s2.kind='def' AND m.kind IN ('include','extend')
                        );
                        defer mix_stmt.reset();
                        mix_stmt.bind_text(1, current);
                        while (try mix_stmt.step()) {
                            const mname2 = mix_stmt.column_text(0);
                            if (seen_names.contains(mname2)) continue;
                            try seen_names.put(try ma.dupe(u8, mname2), {});
                            if (!first_dot) try wd.writeByte(',');
                            first_dot = false;
                            const mdoc = mix_stmt.column_text(1);
                            try wd.writeAll("{\"label\":");
                            try writeEscapedJson(wd, mname2);
                            try wd.writeAll(",\"kind\":3,\"detail\":\"(def)\",\"sortText\":\"0_");
                            try writeEscapedJsonContent(wd, mname2);
                            try wd.writeAll("\",\"filterText\":\"");
                            try writeEscapedJsonContent(wd, mname2);
                            try wd.writeAll("\",\"commitCharacters\":[\"(\"]");
                            if (mdoc.len > 0) {
                                try wd.writeAll(",\"documentation\":\"");
                                try writeEscapedJsonContent(wd, mdoc);
                                try wd.writeByte('"');
                            }
                            try wd.writeAll(",\"textEdit\":{\"range\":{\"start\":{\"line\":");
                            try wd.print("{d}", .{line});
                            try wd.writeAll(",\"character\":");
                            try wd.print("{d}", .{character});
                            try wd.writeAll("},\"end\":{\"line\":");
                            try wd.print("{d}", .{line});
                            try wd.writeAll(",\"character\":");
                            try wd.print("{d}", .{character});
                            try wd.writeAll("}},\"newText\":\"");
                            try writeEscapedJsonContent(wd, mname2);
                            try wd.writeAll("\"},\"data\":{\"name\":");
                            try writeEscapedJson(wd, mname2);
                            try wd.writeAll("}");
                            try wd.writeByte('}');
                        }

                        const par_stmt = try self.cachedStmt("SELECT parent_name FROM symbols WHERE kind='class' AND name=? AND parent_name IS NOT NULL LIMIT 1");
                        defer par_stmt.reset();
                        par_stmt.bind_text(1, current);
                        if (try par_stmt.step()) {
                            const pname = par_stmt.column_text(0);
                            if (pname.len == 0) break;
                            current = try ma.dupe(u8, pname);
                        } else break;
                    }
                } // end union_it loop
                var has_enumerable = false;
                var has_comparable = false;
                {
                    const enum_stmt = self.cachedStmt("SELECT module_name FROM mixins WHERE class_id IN (SELECT id FROM symbols WHERE kind IN ('class','module') AND name=?) AND kind IN ('include','prepend')") catch null;
                    if (enum_stmt) |es| {
                        defer es.reset();
                        es.bind_text(1, class_name);
                        while (es.step() catch false) {
                            const mn = es.column_text(0);
                            if (std.mem.eql(u8, mn, "Enumerable")) has_enumerable = true;
                            if (std.mem.eql(u8, mn, "Comparable")) has_comparable = true;
                        }
                    }
                }
                if (has_enumerable) {
                    const enum_methods = [_][]const u8{
                        "map",     "select",   "reject", "each",       "each_with_index", "each_with_object",
                        "find",    "detect",   "any?",   "all?",       "none?",           "count",
                        "first",   "min",      "max",    "min_by",     "max_by",          "sort",
                        "sort_by", "flat_map", "reduce", "inject",     "include?",        "group_by",
                        "zip",     "take",     "drop",   "to_a",       "each_slice",      "each_cons",
                        "chunk",   "tally",    "sum",    "filter_map",
                    };
                    for (enum_methods) |em| {
                        if (seen_names.contains(em)) continue;
                        if (!first_dot) try wd.writeByte(',');
                        first_dot = false;
                        try wd.writeAll("{\"label\":");
                        try writeEscapedJson(wd, em);
                        try wd.writeAll(",\"kind\":2}");
                    }
                }
                if (has_comparable) {
                    const cmp_methods = [_][]const u8{ "<", ">", "<=", ">=", "between?", "clamp" };
                    for (cmp_methods) |cm| {
                        if (seen_names.contains(cm)) continue;
                        if (!first_dot) try wd.writeByte(',');
                        first_dot = false;
                        try wd.writeAll("{\"label\":");
                        try writeEscapedJson(wd, cm);
                        try wd.writeAll(",\"kind\":2}");
                    }
                }
                try addStdlibCompletions(wd, class_name, &first_dot, line, character);
                try wd.writeAll("]}");

                return types.ResponseMessage{
                    .id = msg.id,
                    .result = null,
                    .raw_result = try aw_dot.toOwnedSlice(),
                    .@"error" = null,
                };
            }
        }
    }
    return null;
}

