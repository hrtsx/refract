const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const erb_mapping = @import("erb_mapping.zig");
const indexer = @import("../indexer/index.zig");
const snippets = @import("snippets.zig");

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

pub const RequireKind = enum { require, require_relative };

pub fn detectRequireContext(source: []const u8, offset: usize) ?RequireKind {
    if (offset == 0) return null;
    var i = offset;
    // Skip back over any partial string
    while (i > 0 and source[i - 1] != '\'' and source[i - 1] != '"') i -= 1;
    if (i == 0) return null;
    i -= 1; // skip the opening quote
    // Skip whitespace
    while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t')) i -= 1;
    // Check for 'require_relative' (16 chars) or 'require' (7 chars)
    if (i >= 16 and std.mem.eql(u8, source[i - 16 .. i], "require_relative")) return .require_relative;
    if (i >= 7 and std.mem.eql(u8, source[i - 7 .. i], "require")) return .require;
    return null;
}

pub fn completeRequirePath(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, offset: usize) !types.ResponseMessage {
    const req_kind = detectRequireContext(source, offset).?;
    const prefix_start = blk: {
        var idx = offset;
        while (idx > 0 and source[idx - 1] != '\'' and source[idx - 1] != '"') idx -= 1;
        break :blk idx;
    };
    const prefix = source[prefix_start..offset];
    var aw_req = std.Io.Writer.Allocating.init(self.alloc);
    const wr = &aw_req.writer;
    try wr.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first_req = true;
    if (req_kind == .require) {
        const stdlib = [_][]const u8{
            "json",      "set",          "date",      "pathname", "fileutils",        "ostruct",
            "digest",    "base64",       "uri",       "net/http", "open-uri",         "tempfile",
            "stringio",  "securerandom", "yaml",      "csv",      "optparse",         "logger",
            "singleton", "forwardable",  "delegate",  "observer", "thread",           "mutex_m",
            "monitor",   "timeout",      "benchmark", "pp",       "pstore",           "dbm",
            "socket",    "resolv",       "zlib",      "rake",     "minitest/autorun", "test/unit",
        };
        for (stdlib) |lib| {
            if (prefix.len == 0 or std.mem.startsWith(u8, lib, prefix)) {
                if (!first_req) try wr.writeByte(',');
                first_req = false;
                try wr.writeAll("{\"label\":");
                try writeEscapedJson(wr, lib);
                try wr.writeAll(",\"kind\":17}");
            }
        }
    }
    if (req_kind == .require_relative) {
        const dir_path = std.fs.path.dirname(path) orelse ".";
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            try wr.writeAll("]}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_req.toOwnedSlice(), .@"error" = null };
        };
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".rb")) continue;
            const stem = entry.name[0 .. entry.name.len - 3];
            const rel = try std.fmt.allocPrint(self.alloc, "./{s}", .{stem});
            defer self.alloc.free(rel);
            if (prefix.len == 0 or std.mem.startsWith(u8, rel, prefix)) {
                if (!first_req) try wr.writeByte(',');
                first_req = false;
                try wr.writeAll("{\"label\":");
                try writeEscapedJson(wr, rel);
                try wr.writeAll(",\"kind\":17}");
            }
        }
    }
    try wr.writeAll("]}");
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_req.toOwnedSlice(), .@"error" = null };
}

pub fn completeDot(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, character: u32, offset: usize, word: []const u8) !?types.ResponseMessage {
    _ = word;
    var recv_offset = if (offset >= 2) offset - 2 else 0;
    var recv_word = extractWord(source, recv_offset);
    if (recv_word.len == 0 and recv_offset > 0 and source[recv_offset] == '&') {
        recv_offset = if (recv_offset >= 1) recv_offset - 1 else 0;
        recv_word = extractWord(source, recv_offset);
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
                    const outer_word = extractWord(source, outer_offset);
                    if (outer_word.len > 0) {
                        const oth_stmt = try self.cachedStmt("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1");
                        defer oth_stmt.reset();
                        oth_stmt.bind_int(1, fdc_id);
                        oth_stmt.bind_text(2, outer_word);
                        oth_stmt.bind_int(3, cursor_line_db);
                        if (try oth_stmt.step()) {
                            const outer_type = oth_stmt.column_text(0);
                            if (outer_type.len > 0) {
                                const resolved_outer = extractBaseClass(outer_type);
                                const ret_stmt = try self.cachedStmt("SELECT return_type FROM symbols WHERE name=? AND kind='def' AND return_type IS NOT NULL AND file_id IN (SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?) LIMIT 1");
                                defer ret_stmt.reset();
                                ret_stmt.bind_text(1, recv_word);
                                ret_stmt.bind_text(2, resolved_outer);
                                if (try ret_stmt.step()) {
                                    const cc = ret_stmt.column_text(0);
                                    if (cc.len > 0) chain_class_buf = try self.alloc.dupe(u8, cc);
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
                const enclosing_class_stmt = try self.db.prepare("SELECT id FROM symbols WHERE file_id=? AND kind IN ('class','module') AND line<=? ORDER BY line DESC LIMIT 1");
                defer enclosing_class_stmt.finalize();
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
                const sc_stmt = try self.db.prepare("SELECT name FROM symbols WHERE file_id=? AND kind IN ('class','module') AND line<=? ORDER BY line DESC LIMIT 1");
                defer sc_stmt.finalize();
                sc_stmt.bind_int(1, fdc_id);
                sc_stmt.bind_int(2, cursor_line_db);
                if (try sc_stmt.step()) {
                    const sc = sc_stmt.column_text(0);
                    if (sc.len > 0) chain_class_buf = try self.alloc.dupe(u8, sc);
                }
            }
            const is_constant_recv = recv_word.len > 0 and std.ascii.isUpper(recv_word[0]);
            if (chain_class_buf == null and is_constant_recv) {
                chain_class_buf = try self.alloc.dupe(u8, recv_word);
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
                        self.db.prepare(
                            \\SELECT s.name, s.doc,
                            \\  (SELECT GROUP_CONCAT(
                            \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
                            \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
                            \\    ELSE p.name END, ', ')
                            \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position)
                            \\FROM symbols s
                            \\WHERE s.kind='def' AND s.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?
                            \\)
                        ) catch null
                    else
                        self.db.prepare(
                            \\SELECT s.name, s.doc,
                            \\  (SELECT GROUP_CONCAT(
                            \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
                            \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
                            \\    ELSE p.name END, ', ')
                            \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position)
                            \\FROM symbols s
                            \\WHERE s.kind='def' AND s.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?
                            \\) AND (s.visibility IS NULL OR s.visibility = 'public')
                        ) catch null;
                    defer if (own_stmt_hoisted) |s2| s2.finalize();
                    const cls_stmt_hoisted = if (is_constant_recv)
                        self.db.prepare(
                            \\SELECT s.name, s.doc FROM symbols s
                            \\WHERE s.kind='classdef' AND s.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?
                            \\) AND (s.visibility IS NULL OR s.visibility = 'public')
                        ) catch null
                    else
                        null;
                    defer if (cls_stmt_hoisted) |s2| s2.finalize();
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
                        while (try own_stmt.step()) {
                            const mname2 = own_stmt.column_text(0);
                            if (seen_names.contains(mname2)) continue;
                            try seen_names.put(try ma.dupe(u8, mname2), {});
                            if (!first_dot) try wd.writeByte(',');
                            first_dot = false;
                            const mdoc = own_stmt.column_text(1);
                            const msig = own_stmt.column_text(2);
                            try wd.writeAll("{\"label\":");
                            try writeEscapedJson(wd, mname2);
                            try wd.writeAll(",\"kind\":3,\"detail\":\"(def)\",\"sortText\":\"0_");
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
                    const enum_stmt = self.db.prepare("SELECT module_name FROM mixins WHERE class_id IN (SELECT id FROM symbols WHERE kind IN ('class','module') AND name=?) AND kind IN ('include','prepend')") catch null;
                    if (enum_stmt) |es| {
                        defer es.finalize();
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

pub fn completeNamespace(self: *Server, msg: types.RequestMessage, source: []const u8, offset: usize, word: []const u8) !?types.ResponseMessage {
    _ = word;
    const ns_offset = if (offset >= 3) offset - 3 else 0;
    const ns_word = extractWord(source, ns_offset);
    if (ns_word.len == 0) return null;
    const ns_stmt = try self.db.prepare(
        \\SELECT name, kind
        \\FROM symbols
        \\WHERE parent_name = ?
        \\  AND kind IN ('classdef', 'moduledef', 'constant', 'def', 'class', 'module')
        \\ORDER BY name LIMIT 100
    );
    defer ns_stmt.finalize();
    ns_stmt.bind_text(1, ns_word);
    var aw_ns = std.Io.Writer.Allocating.init(self.alloc);
    const wns = &aw_ns.writer;
    try wns.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first_ns = true;
    while (try ns_stmt.step()) {
        if (!first_ns) try wns.writeByte(',');
        first_ns = false;
        const cname = ns_stmt.column_text(0);
        const ckind_str = ns_stmt.column_text(1);
        const ckind_num: u8 = if (std.mem.eql(u8, ckind_str, "classdef") or std.mem.eql(u8, ckind_str, "class")) 7 else if (std.mem.eql(u8, ckind_str, "moduledef") or std.mem.eql(u8, ckind_str, "module")) 9 else if (std.mem.eql(u8, ckind_str, "constant")) 21 else 3;
        try wns.writeAll("{\"label\":");
        try writeEscapedJson(wns, cname);
        try wns.print(",\"kind\":{d}", .{ckind_num});
        try wns.writeByte('}');
    }
    try wns.writeAll("]}");
    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw_ns.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn completeAllSymbols(self: *Server, msg: types.RequestMessage) !types.ResponseMessage {
    const stmt2 = try self.db.prepare(
        \\SELECT DISTINCT name, kind FROM symbols ORDER BY length(name), name LIMIT 500
    );
    defer stmt2.finalize();
    var items_aw2 = std.Io.Writer.Allocating.init(self.alloc);
    var first2 = true;
    var count2: usize = 0;
    while (try stmt2.step()) {
        if (!first2) try items_aw2.writer.writeByte(',');
        first2 = false;
        count2 += 1;
        const cname = stmt2.column_text(0);
        const ckind_str = stmt2.column_text(1);
        const ckind_num: u8 = if (std.mem.eql(u8, ckind_str, "class")) 7 else if (std.mem.eql(u8, ckind_str, "module")) 9 else if (std.mem.eql(u8, ckind_str, "def") or std.mem.eql(u8, ckind_str, "classdef")) 3 else if (std.mem.eql(u8, ckind_str, "constant")) 21 else 1;
        try items_aw2.writer.writeAll("{\"label\":");
        try writeEscapedJson(&items_aw2.writer, cname);
        try items_aw2.writer.print(",\"kind\":{d},\"detail\":\"(", .{ckind_num});
        try writeEscapedJsonContent(&items_aw2.writer, ckind_str);
        try items_aw2.writer.writeAll(")\"");
        const csort_prefix: []const u8 = if (std.mem.eql(u8, ckind_str, "def") or std.mem.eql(u8, ckind_str, "classdef")) "0_" else if (std.mem.eql(u8, ckind_str, "class") or std.mem.eql(u8, ckind_str, "module")) "1_" else "2_";
        try items_aw2.writer.writeAll(",\"sortText\":\"");
        try writeEscapedJsonContent(&items_aw2.writer, csort_prefix);
        try writeEscapedJsonContent(&items_aw2.writer, cname);
        try items_aw2.writer.writeByte('"');
        try items_aw2.writer.writeAll(",\"filterText\":\"");
        try writeEscapedJsonContent(&items_aw2.writer, cname);
        try items_aw2.writer.writeByte('"');
        if (std.mem.eql(u8, ckind_str, "def") or std.mem.eql(u8, ckind_str, "classdef")) {
            try items_aw2.writer.writeAll(",\"commitCharacters\":[\"(\"]");
        }
        try items_aw2.writer.writeByte('}');
    }
    const items2 = try items_aw2.toOwnedSlice();
    defer self.alloc.free(items2);
    var aw2 = std.Io.Writer.Allocating.init(self.alloc);
    const w2 = &aw2.writer;
    try w2.writeAll(if (count2 >= 200) "{\"isIncomplete\":true,\"items\":[" else "{\"isIncomplete\":false,\"items\":[");
    try w2.writeAll(items2);
    try w2.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw2.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn completeInstanceVars(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, word: []const u8) !types.ResponseMessage {
    _ = source;
    const ivar_pattern = try buildQueryPattern(self.alloc, word);
    defer self.alloc.free(ivar_pattern);
    const ifc_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer ifc_stmt.finalize();
    ifc_stmt.bind_text(1, path);
    var aw_iv = std.Io.Writer.Allocating.init(self.alloc);
    const wi = &aw_iv.writer;
    try wi.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first_iv = true;
    if (try ifc_stmt.step()) {
        const fid = ifc_stmt.column_int(0);
        const cls_stmt = self.db.prepare("SELECT id FROM symbols WHERE file_id=? AND line<=? AND (kind='class' OR kind='module') ORDER BY line DESC LIMIT 1") catch null;
        const class_id: i64 = blk: {
            if (cls_stmt) |cs| {
                defer cs.finalize();
                cs.bind_int(1, fid);
                cs.bind_int(2, @intCast(line + 1));
                if (cs.step() catch false) break :blk cs.column_int(0);
            }
            break :blk 0;
        };
        const iv_stmt = try self.db.prepare("SELECT DISTINCT name, type_hint FROM local_vars WHERE file_id=? AND (class_id=? OR class_id IS NULL) AND name LIKE ? ESCAPE '\\'");
        defer iv_stmt.finalize();
        iv_stmt.bind_int(1, fid);
        iv_stmt.bind_int(2, class_id);
        iv_stmt.bind_text(3, ivar_pattern);
        while (try iv_stmt.step()) {
            const iv_name = iv_stmt.column_text(0);
            const iv_type = iv_stmt.column_text(1);
            if (!first_iv) try wi.writeByte(',');
            first_iv = false;
            try wi.writeAll("{\"label\":");
            try writeEscapedJson(wi, iv_name);
            try wi.writeAll(",\"kind\":5");
            if (iv_type.len > 0) {
                try wi.writeAll(",\"detail\":\"");
                try writeEscapedJsonContent(wi, iv_type);
                try wi.writeByte('"');
            }
            try wi.writeAll(",\"sortText\":\"2_");
            try writeEscapedJsonContent(wi, iv_name);
            try wi.writeByte('"');
            try wi.writeAll(",\"filterText\":\"");
            try writeEscapedJsonContent(wi, iv_name);
            try wi.writeByte('"');
            try wi.writeByte('}');
        }
    }
    try wi.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw_iv.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn completeGlobalVars(self: *Server, msg: types.RequestMessage, word: []const u8) !types.ResponseMessage {
    const gv_pat = try buildPrefixPattern(self.alloc, word);
    defer self.alloc.free(gv_pat);
    const gv_stmt = try self.db.prepare(
        \\SELECT DISTINCT name FROM local_vars
        \\WHERE name LIKE ? ESCAPE '\'
        \\ORDER BY name LIMIT 200
    );
    defer gv_stmt.finalize();
    gv_stmt.bind_text(1, gv_pat);
    var aw_gv = std.Io.Writer.Allocating.init(self.alloc);
    const wg = &aw_gv.writer;
    try wg.writeAll("{\"isIncomplete\":false,\"items\":[");
    var gv_first = true;
    var gv_seen_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer gv_seen_arena.deinit();
    var gv_seen = std.StringHashMap(void).init(gv_seen_arena.allocator());
    while (try gv_stmt.step()) {
        const gv_name = gv_stmt.column_text(0);
        if (gv_seen.contains(gv_name)) continue;
        gv_seen.put(try gv_seen_arena.allocator().dupe(u8, gv_name), {}) catch {}; // OOM: seen set
        if (!gv_first) try wg.writeByte(',');
        gv_first = false;
        try wg.writeAll("{\"label\":");
        try writeEscapedJson(wg, gv_name);
        try wg.writeAll(",\"kind\":6,\"sortText\":\"1_");
        try writeEscapedJsonContent(wg, gv_name);
        try wg.writeAll("\",\"filterText\":");
        try writeEscapedJson(wg, gv_name);
        try wg.writeByte('}');
    }
    const ruby_globals = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "$stdout", .doc = "Standard output stream." },
        .{ .name = "$stderr", .doc = "Standard error stream." },
        .{ .name = "$stdin", .doc = "Standard input stream." },
        .{ .name = "$PROGRAM_NAME", .doc = "Current script name (same as $0)." },
        .{ .name = "$0", .doc = "Current script name." },
        .{ .name = "$LOAD_PATH", .doc = "Load path array (same as $:)." },
        .{ .name = "$:", .doc = "Load path array." },
        .{ .name = "$LOADED_FEATURES", .doc = "Loaded files array (same as $\")." },
        .{ .name = "$VERBOSE", .doc = "Verbose mode flag." },
        .{ .name = "$DEBUG", .doc = "Debug mode flag." },
        .{ .name = "$?", .doc = "Exit status of last child process." },
        .{ .name = "$~", .doc = "MatchData from last match." },
        .{ .name = "$&", .doc = "String matched by last regex." },
        .{ .name = "$1", .doc = "First capture group of last match." },
        .{ .name = "$2", .doc = "Second capture group of last match." },
        .{ .name = "$3", .doc = "Third capture group of last match." },
    };
    for (ruby_globals) |rg| {
        if (!std.mem.startsWith(u8, rg.name, word)) continue;
        if (gv_seen.contains(rg.name)) continue;
        if (!gv_first) try wg.writeByte(',');
        gv_first = false;
        try wg.writeAll("{\"label\":");
        try writeEscapedJson(wg, rg.name);
        try wg.writeAll(",\"kind\":6,\"detail\":\"(built-in)\",\"documentation\":{\"kind\":\"plaintext\",\"value\":");
        try writeEscapedJson(wg, rg.doc);
        try wg.writeAll("},\"sortText\":\"9_");
        try writeEscapedJsonContent(wg, rg.name);
        try wg.writeAll("\",\"filterText\":");
        try writeEscapedJson(wg, rg.name);
        try wg.writeByte('}');
    }
    try wg.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw_gv.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn completeI18n(self: *Server, msg: types.RequestMessage, source: []const u8, offset: usize) !types.ResponseMessage {
    var key_start = offset;
    while (key_start > 0 and source[key_start - 1] != '"' and source[key_start - 1] != '\'') {
        key_start -= 1;
    }
    if (key_start > 0) key_start -= 1;
    if (key_start >= source.len) return emptyResult(msg).?;
    key_start += 1;
    const partial_key = source[key_start..offset];

    const i18n_pattern = try buildPrefixPattern(self.alloc, partial_key);
    defer self.alloc.free(i18n_pattern);

    const stmt = self.db.prepare(
        \\SELECT DISTINCT key, value FROM i18n_keys
        \\WHERE key LIKE ? ESCAPE '\'
        \\ORDER BY key LIMIT 50
    ) catch return emptyResult(msg).?;
    defer stmt.finalize();
    stmt.bind_text(1, i18n_pattern);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first = true;
    while (try stmt.step()) {
        const key = stmt.column_text(0);
        const value = stmt.column_text(1);
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"label\":");
        try writeEscapedJson(w, key);
        try w.writeAll(",\"kind\":12,\"detail\":");
        try writeEscapedJson(w, value);
        try w.writeByte('}');
    }
    try w.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn completeRouteHelpers(self: *Server, msg: types.RequestMessage, word: []const u8) !types.ResponseMessage {
    if (word.len < 2) return emptyResult(msg).?;

    const route_pattern = try buildPrefixPattern(self.alloc, word);
    defer self.alloc.free(route_pattern);

    const stmt = self.db.prepare(
        \\SELECT helper_name, http_method, path_pattern FROM routes
        \\WHERE helper_name LIKE ? ESCAPE '\'
        \\ORDER BY helper_name LIMIT 50
    ) catch return emptyResult(msg).?;
    defer stmt.finalize();
    stmt.bind_text(1, route_pattern);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first = true;
    while (try stmt.step()) {
        const helper_name = stmt.column_text(0);
        const http_method = stmt.column_text(1);
        const path_pattern = stmt.column_text(2);

        if (!first) try w.writeByte(',');
        first = false;

        try w.writeAll("{\"label\":");
        try writeEscapedJson(w, helper_name);
        try w.writeAll(",\"kind\":3,\"detail\":");
        try w.writeByte('"');
        try writeEscapedJsonContent(w, http_method);
        try w.writeAll(" ");
        try writeEscapedJsonContent(w, path_pattern);
        try w.writeAll("\",\"sortText\":\"1_");
        try writeEscapedJsonContent(w, helper_name);
        try w.writeByte('}');
    }
    try w.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn completeGeneral(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, character: u32, word: []const u8, offset: usize) !types.ResponseMessage {
    const pattern = try buildQueryPattern(self.alloc, word);
    defer self.alloc.free(pattern);
    const prefix_pattern = try buildPrefixPattern(self.alloc, word);
    defer self.alloc.free(prefix_pattern);

    const stmt = try self.db.prepare(
        \\SELECT s.name, s.kind,
        \\  (SELECT GROUP_CONCAT(
        \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
        \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
        \\    ELSE p.name END, ', ')
        \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position),
        \\  s.doc
        \\FROM symbols s WHERE s.name LIKE ? ESCAPE '\'
        \\ORDER BY CASE WHEN s.name LIKE ? ESCAPE '\' THEN 0 ELSE 1 END, length(s.name), s.name LIMIT 1000
    );
    defer stmt.finalize();
    stmt.bind_text(1, pattern);
    stmt.bind_text(2, prefix_pattern);

    var seen_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer seen_arena.deinit();
    var seen = std.StringHashMap(void).init(seen_arena.allocator());

    var items_aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &items_aw.writer;
    var first = true;
    var symbol_count: usize = 0;
    while (try stmt.step()) {
        const name = stmt.column_text(0);
        if (seen.contains(name)) continue;
        try seen.put(try seen_arena.allocator().dupe(u8, name), {});
        if (!first) try w.writeByte(',');
        first = false;
        symbol_count += 1;
        const kind_str = stmt.column_text(1);
        const sig = stmt.column_text(2);
        const doc = stmt.column_text(3);
        const kind_num: u8 = if (std.mem.eql(u8, kind_str, "class")) 7 else if (std.mem.eql(u8, kind_str, "module")) 9 else if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) 3 else if (std.mem.eql(u8, kind_str, "constant")) 21 else 1;
        try w.writeAll("{\"label\":");
        try writeEscapedJson(w, name);
        try w.print(",\"kind\":{d},\"detail\":\"(", .{kind_num});
        if ((std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) and sig.len > 0) {
            try writeEscapedJsonContent(w, sig);
        } else {
            try writeEscapedJsonContent(w, kind_str);
        }
        try w.writeAll(")\"");
        const sort_prefix: []const u8 = if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) "0_" else if (std.mem.eql(u8, kind_str, "class") or std.mem.eql(u8, kind_str, "module")) "1_" else "2_";
        try w.writeAll(",\"sortText\":\"");
        try writeEscapedJsonContent(w, sort_prefix);
        try writeEscapedJsonContent(w, name);
        try w.writeByte('"');
        try w.writeAll(",\"filterText\":\"");
        try writeEscapedJsonContent(w, name);
        try w.writeByte('"');
        if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) {
            try w.writeAll(",\"commitCharacters\":[\"(\"]");
        }
        if ((std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) and sig.len > 0) {
            writeInsertTextSnippet(w, name, sig) catch {}; // response building
        }
        if (doc.len > 0) {
            try w.writeAll(",\"documentation\":{\"kind\":\"markdown\",\"value\":");
            try writeEscapedJson(w, doc);
            try w.writeByte('}');
        }
        const te_start_char = @as(u32, @intCast(character)) -| @as(u32, @intCast(word.len));
        try w.print(",\"textEdit\":{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":", .{
            line, te_start_char, line, character,
        });
        try writeEscapedJson(w, name);
        try w.writeByte('}');
        try w.writeByte('}');
    }
    const truncated = symbol_count >= 1000;

    if (word.len <= 9) {
        const kw_items = [_]struct { label: []const u8, snippet: []const u8, kind: u8 }{
            .{ .label = "def", .snippet = "def ${1:method_name}\\n  $0\\nend", .kind = 3 },
            .{ .label = "class", .snippet = "class ${1:ClassName}\\n  $0\\nend", .kind = 7 },
            .{ .label = "module", .snippet = "module ${1:ModuleName}\\n  $0\\nend", .kind = 9 },
            .{ .label = "if", .snippet = "if ${1:condition}\\n  $0\\nend", .kind = 14 },
            .{ .label = "unless", .snippet = "unless ${1:condition}\\n  $0\\nend", .kind = 14 },
            .{ .label = "while", .snippet = "while ${1:condition}\\n  $0\\nend", .kind = 14 },
            .{ .label = "until", .snippet = "until ${1:condition}\\n  $0\\nend", .kind = 14 },
            .{ .label = "begin", .snippet = "begin\\n  $0\\nrescue => e\\n  raise\\nend", .kind = 14 },
            .{ .label = "do", .snippet = "do |${1:arg}|\\n  $0\\nend", .kind = 14 },
        };
        for (kw_items) |ki| {
            if (word.len > 0 and !std.mem.startsWith(u8, ki.label, word)) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"label\":");
            try writeEscapedJson(w, ki.label);
            try w.print(",\"kind\":{d},\"insertTextFormat\":2,\"insertText\":", .{ki.kind});
            try writeEscapedJson(w, ki.snippet);
            try w.writeAll(",\"sortText\":\"z_kw_");
            try writeEscapedJsonContent(w, ki.label);
            try w.writeByte('"');
            try w.writeByte('}');
        }
    }

    const fc_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer fc_stmt.finalize();
    fc_stmt.bind_text(1, path);
    if (try fc_stmt.step()) {
        const fid = fc_stmt.column_int(0);
        const lv_stmt = try self.db.prepare("SELECT DISTINCT name, type_hint FROM local_vars WHERE file_id = ? AND name LIKE ? ESCAPE '\\'");
        defer lv_stmt.finalize();
        lv_stmt.bind_int(1, fid);
        lv_stmt.bind_text(2, pattern);
        while (try lv_stmt.step()) {
            const lv_name = lv_stmt.column_text(0);
            if (seen.contains(lv_name)) continue;
            try seen.put(try seen_arena.allocator().dupe(u8, lv_name), {});
            const lv_type = lv_stmt.column_text(1);
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"label\":");
            try writeEscapedJson(w, lv_name);
            try w.writeAll(",\"kind\":6");
            if (lv_type.len > 0) {
                try w.writeAll(",\"detail\":\"");
                try writeEscapedJsonContent(w, lv_type);
                try w.writeByte('"');
            }
            try w.writeAll(",\"sortText\":\"2_");
            try writeEscapedJsonContent(w, lv_name);
            try w.writeByte('"');
            try w.writeAll(",\"filterText\":\"");
            try writeEscapedJsonContent(w, lv_name);
            try w.writeByte('"');
            try w.writeByte('}');
        }
    }

    const word_start_pos: usize = if (offset >= word.len) offset - word.len else 0;
    const is_dot_context = word_start_pos > 0 and source[word_start_pos - 1] == '.';
    if (!is_dot_context) {
        const kernel_methods = [_]struct { name: []const u8, doc: []const u8 }{
            .{ .name = "puts", .doc = "Writes to stdout followed by newline." },
            .{ .name = "print", .doc = "Writes to stdout without newline." },
            .{ .name = "p", .doc = "Inspects and prints objects, returns them." },
            .{ .name = "pp", .doc = "Pretty-prints objects." },
            .{ .name = "require", .doc = "Loads a library." },
            .{ .name = "require_relative", .doc = "Loads library relative to current file." },
            .{ .name = "raise", .doc = "Raises an exception." },
            .{ .name = "fail", .doc = "Alias for raise." },
            .{ .name = "rand", .doc = "Returns a random number." },
            .{ .name = "sleep", .doc = "Suspends for duration." },
            .{ .name = "lambda", .doc = "Creates a lambda proc." },
            .{ .name = "proc", .doc = "Creates a proc object." },
            .{ .name = "format", .doc = "Formats a string." },
            .{ .name = "sprintf", .doc = "Formats a string." },
            .{ .name = "loop", .doc = "Loops forever, calling the block." },
            .{ .name = "at_exit", .doc = "Registers a block to run at exit." },
            .{ .name = "abort", .doc = "Prints message and exits with failure." },
            .{ .name = "exit", .doc = "Exits the process." },
        };
        for (kernel_methods) |km| {
            if (word.len > 0 and !std.mem.startsWith(u8, km.name, word)) continue;
            if (seen.contains(km.name)) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"label\":");
            try writeEscapedJson(w, km.name);
            try w.writeAll(",\"kind\":3,\"detail\":\"(Kernel)\",\"documentation\":{\"kind\":\"plaintext\",\"value\":");
            try writeEscapedJson(w, km.doc);
            try w.writeAll("},\"sortText\":\"9_");
            try writeEscapedJsonContent(w, km.name);
            try w.writeByte('"');
            try w.writeAll(",\"filterText\":\"");
            try writeEscapedJsonContent(w, km.name);
            try w.writeByte('"');
            try w.writeByte('}');
        }
    }

    kw_params_detect: {
        var kp_scan: usize = offset;
        var kp_depth: i32 = 0;
        var kp_open: ?usize = null;
        while (kp_scan > 0) {
            kp_scan -= 1;
            switch (source[kp_scan]) {
                ')', ']', '}' => kp_depth += 1,
                '(' => {
                    if (kp_depth == 0) {
                        kp_open = kp_scan;
                        break;
                    }
                    kp_depth -= 1;
                },
                '[', '{' => {
                    if (kp_depth > 0) {
                        kp_depth -= 1;
                    } else break :kw_params_detect;
                },
                '\n' => break :kw_params_detect,
                else => {},
            }
        }
        const kco = kp_open orelse break :kw_params_detect;
        const kp_method = extractWord(source, if (kco > 0) kco - 1 else 0);
        if (kp_method.len == 0) break :kw_params_detect;
        const kp_q = self.db.prepare("SELECT p.name FROM params p JOIN symbols s ON p.symbol_id=s.id WHERE s.name=? AND s.kind='def' AND p.kind='keyword' ORDER BY p.position LIMIT 20") catch break :kw_params_detect;
        defer kp_q.finalize();
        kp_q.bind_text(1, kp_method);
        while (kp_q.step() catch false) {
            const pname = kp_q.column_text(0);
            if (word.len > 0 and !std.mem.startsWith(u8, pname, word)) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"label\":\"");
            try writeEscapedJsonContent(w, pname);
            try w.writeAll(":\",\"filterText\":\"");
            try writeEscapedJsonContent(w, pname);
            try w.writeAll("\",\"insertText\":\"");
            try writeEscapedJsonContent(w, pname);
            try w.writeAll(": \",\"kind\":5,\"sortText\":\"0_");
            try writeEscapedJsonContent(w, pname);
            try w.writeByte('"');
            try w.writeByte('}');
        }
    }

    // Append snippet completions when user is typing a word
    if (word.len > 0) {
        const te_col = character -| @as(u32, @intCast(word.len));
        var has_prev = !first;
        const snip_arrays = [_][]const snippets.Snippet{
            &snippets.RUBY_SNIPPETS, &snippets.RAILS_SNIPPETS, &snippets.RSPEC_SNIPPETS,
        };
        for (snip_arrays) |arr| {
            for (arr) |snippet| {
                if (std.mem.startsWith(u8, snippet.trigger, word)) {
                    if (has_prev) try w.writeByte(',');
                    has_prev = true;
                    try w.writeAll("{\"label\":");
                    try writeEscapedJson(w, snippet.label);
                    try w.writeAll(",\"kind\":15,\"insertTextFormat\":2,\"detail\":");
                    try writeEscapedJson(w, snippet.detail);
                    try w.writeAll(",\"sortText\":\"");
                    try writeEscapedJsonContent(w, snippet.sort_prefix);
                    try writeEscapedJsonContent(w, snippet.trigger);
                    try w.writeAll("\",\"filterText\":");
                    try writeEscapedJson(w, snippet.trigger);
                    try w.print(",\"textEdit\":{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":", .{
                        line, te_col, line, character,
                    });
                    try writeEscapedJson(w, snippet.body);
                    try w.writeAll("}}");
                }
            }
        }
    }

    const items_json = try items_aw.toOwnedSlice();
    defer self.alloc.free(items_json);
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const wr = &aw.writer;
    try wr.writeAll(if (truncated) "{\"isIncomplete\":true,\"items\":[" else "{\"isIncomplete\":false,\"items\":[");
    try wr.writeAll(items_json);
    try wr.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn handleCompletion(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.flushDirtyUris();
    if (self.isCancelled(msg.id)) return null;
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
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

    if (std.mem.endsWith(u8, path, ".erb") and !erb_mapping.isErbRubyContext(source, offset)) {
        var aw_erb = std.Io.Writer.Allocating.init(self.alloc);
        const ew = &aw_erb.writer;
        try ew.writeAll("{\"isIncomplete\":false,\"items\":[");
        var erb_first = true;
        for (erb_mapping.RAILS_VIEW_HELPERS) |helper| {
            if (!erb_first) try ew.writeByte(',');
            erb_first = false;
            try ew.writeAll("{\"label\":");
            try writeEscapedJson(ew, helper.name);
            try ew.writeAll(",\"kind\":3,\"detail\":");
            try writeEscapedJson(ew, helper.detail);
            try ew.writeAll(",\"insertTextFormat\":2,\"insertText\":");
            try writeEscapedJson(ew, helper.snippet);
            try ew.writeByte('}');
        }
        try ew.writeAll("]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_erb.toOwnedSlice(), .@"error" = null };
    }

    const word = extractWord(source, offset);

    if (detectRequireContext(source, offset) != null)
        return try completeRequirePath(self, msg, path, source, offset);
    if (Server.detectI18nContext(source, offset))
        return try completeI18n(self, msg, source, offset);
    if (isInStringOrComment(source, offset)) {
        var aw_empty = std.Io.Writer.Allocating.init(self.alloc);
        try aw_empty.writer.writeAll("{\"isIncomplete\":false,\"items\":[]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_empty.toOwnedSlice(), .@"error" = null };
    }
    if (word.len == 0 and offset > 0 and source[offset - 1] == '.')
        if (try completeDot(self, msg, path, source, line, character, offset, word)) |r| return r;
    if (word.len == 0 and offset >= 2 and source[offset - 1] == ':' and source[offset - 2] == ':')
        if (try completeNamespace(self, msg, source, offset, word)) |r| return r;
    if (word.len == 0)
        return try completeAllSymbols(self, msg);
    if (word.len > 0 and word[0] == '@')
        return try completeInstanceVars(self, msg, path, source, line, word);
    if (word.len > 0 and word[0] == '$')
        return try completeGlobalVars(self, msg, word);
    if (word.len > 0 and (std.mem.endsWith(u8, word, "_path") or std.mem.endsWith(u8, word, "_url") or std.mem.endsWith(u8, word, "_p") or std.mem.endsWith(u8, word, "_u")))
        return try completeRouteHelpers(self, msg, word);
    return try completeGeneral(self, msg, path, source, line, character, word, offset);
}

pub fn handleCompletionItemResolve(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.db_mutex.lock();
    defer self.db_mutex.unlock();
    const params = msg.params orelse return emptyResult(msg);
    const item_obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };

    const data_val = item_obj.get("data") orelse {
        const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = raw,
            .@"error" = null,
        };
    };
    const data_obj = switch (data_val) {
        .object => |o| o,
        else => {
            const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = raw,
                .@"error" = null,
            };
        },
    };
    const name_val = data_obj.get("name") orelse {
        const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = raw,
            .@"error" = null,
        };
    };
    const name = switch (name_val) {
        .string => |s| s,
        else => {
            const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = raw,
                .@"error" = null,
            };
        },
    };

    const def_stmt = try self.db.prepare("SELECT doc, return_type FROM symbols WHERE name = ? AND kind = 'def' LIMIT 1");
    defer def_stmt.finalize();
    def_stmt.bind_text(1, name);
    if (!(try def_stmt.step())) {
        const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = raw,
            .@"error" = null,
        };
    }

    const doc = def_stmt.column_text(0);
    const return_type = def_stmt.column_text(1);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('{');

    var first_field = true;
    var iter = item_obj.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "data")) continue;
        if (!first_field) try w.writeByte(',');
        first_field = false;
        try writeEscapedJson(w, entry.key_ptr.*);
        try w.writeByte(':');
        const val_str = std.json.Stringify.valueAlloc(self.alloc, entry.value_ptr.*, .{}) catch "null";
        defer self.alloc.free(val_str);
        try w.writeAll(val_str);
    }

    if (return_type.len > 0) {
        if (!first_field) try w.writeByte(',');
        first_field = false;
        try w.writeAll("\"detail\":\"");
        try w.writeAll("\u{2192} ");
        try writeEscapedJsonContent(w, return_type);
        try w.writeByte('"');
    }

    if (doc.len > 0) {
        if (!first_field) try w.writeByte(',');
        first_field = false;
        try w.writeAll("\"documentation\":{\"kind\":\"markdown\",\"value\":\"");
        try writeEscapedJsonContent(w, doc);
        try w.writeAll("\"}");
    }

    try w.writeByte('}');

    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn addStdlibCompletions(w: *std.Io.Writer, class_name: []const u8, first_item: *bool, line: u32, character: u32) !void {
    const methods: []const []const u8 = if (std.mem.eql(u8, class_name, "String"))
        &[_][]const u8{ "upcase", "downcase", "strip", "lstrip", "rstrip", "chomp", "chop", "length", "size", "empty?", "include?", "split", "gsub", "sub", "reverse", "start_with?", "end_with?", "to_i", "to_f", "to_sym", "chars", "bytes", "scan", "lines", "match?", "capitalize", "swapcase", "squeeze", "delete", "encode", "tr", "center", "ljust", "rjust", "freeze", "to_s", "count", "bytesize", "hex", "oct", "concat", "prepend", "slice", "valid_encoding?" }
    else if (std.mem.eql(u8, class_name, "Integer") or std.mem.eql(u8, class_name, "Numeric"))
        &[_][]const u8{ "to_s", "to_f", "to_i", "abs", "ceil", "floor", "round", "truncate", "times", "zero?", "positive?", "negative?", "odd?", "even?", "between?", "digits", "divmod", "chr", "next", "succ", "pred", "gcd", "lcm", "upto", "downto", "inspect" }
    else if (std.mem.eql(u8, class_name, "Float"))
        &[_][]const u8{ "to_i", "to_f", "to_s", "ceil", "floor", "round", "truncate", "abs", "positive?", "negative?", "zero?", "finite?", "nan?", "infinite?", "inspect" }
    else if (std.mem.eql(u8, class_name, "Array"))
        &[_][]const u8{ "length", "size", "count", "first", "last", "empty?", "include?", "push", "pop", "shift", "unshift", "append", "prepend", "flatten", "compact", "uniq", "sort", "reverse", "map", "collect", "select", "filter", "reject", "each", "any?", "all?", "none?", "one?", "join", "zip", "sample", "shuffle", "rotate", "tally", "filter_map", "flat_map", "sum", "to_h", "intersection", "union", "difference", "product", "combination", "permutation", "entries" }
    else if (std.mem.eql(u8, class_name, "Hash"))
        &[_][]const u8{ "keys", "values", "each", "map", "select", "filter", "reject", "merge", "update", "delete", "fetch", "has_key?", "key?", "include?", "has_value?", "value?", "empty?", "size", "count", "any?", "all?", "none?", "invert", "compact", "except", "slice", "flat_map", "to_a", "each_with_object", "group_by", "transform_values", "transform_keys", "each_key", "each_value", "each_pair", "deep_symbolize_keys", "deep_stringify_keys", "with_indifferent_access" }
    else if (std.mem.eql(u8, class_name, "Symbol"))
        &[_][]const u8{ "to_s", "id2name", "to_sym", "inspect", "upcase", "downcase", "length", "size", "match?", "empty?", "to_proc" }
    else
        return;
    for (methods) |m| {
        if (!first_item.*) try w.writeByte(',');
        first_item.* = false;
        try w.writeAll("{\"label\":");
        try writeEscapedJson(w, m);
        try w.print(",\"kind\":3,\"detail\":\"(stdlib)\",\"sortText\":\"1_", .{});
        try writeEscapedJsonContent(w, m);
        try w.writeAll("\",\"filterText\":\"");
        try writeEscapedJsonContent(w, m);
        try w.writeAll("\",\"textEdit\":{\"range\":{\"start\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{character});
        try w.writeAll("},\"end\":{\"line\":");
        try w.print("{d}", .{line});
        try w.writeAll(",\"character\":");
        try w.print("{d}", .{character});
        try w.writeAll("}},\"newText\":\"");
        try writeEscapedJsonContent(w, m);
        try w.writeAll("\"},\"data\":{\"name\":");
        try writeEscapedJson(w, m);
        try w.writeAll("}}");
    }
}

pub fn writeInsertTextSnippet(w: *std.Io.Writer, name: []const u8, sig: []const u8) !void {
    try w.writeAll(",\"insertTextFormat\":2,\"insertText\":\"");
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] == '"' or name[i] == '\\') try w.writeByte('\\');
        try w.writeByte(name[i]);
    }
    try w.writeByte('(');
    var n: u32 = 1;
    var it = std.mem.splitSequence(u8, sig, ", ");
    var first_p = true;
    while (it.next()) |param| {
        if (!first_p) try w.writeAll(", ");
        first_p = false;
        try w.print("${{{}:{s}}}", .{ n, param });
        n += 1;
    }
    try w.writeAll(")$0\"");
}
