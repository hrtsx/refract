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

fn kindStr(k: hot_index_mod.SymbolKind) []const u8 {
    return switch (k) {
        .def => "def",
        .classdef => "classdef",
        .class_ => "class",
        .module => "module",
        .constant => "constant",
        .association => "association",
        .scope => "scope",
        .validation => "validation",
        .callback => "callback",
        .test_desc => "test",
        .namespace_label => "namespace",
        .other => "other",
    };
}

fn kindNum(k: hot_index_mod.SymbolKind) u8 {
    return switch (k) {
        .class_ => 7,
        .module => 9,
        .def, .classdef => 3,
        .constant => 21,
        else => 1,
    };
}

const RankedSymbol = struct {
    sym: hot_index_mod.HotSymbol,
    /// 0 = prefix match (LIKE 'word%'), 1 = substring match (LIKE '%word%').
    /// Mirrors the SQL `ORDER BY CASE WHEN s.name LIKE prefix THEN 0 ELSE 1 END`.
    tier: u8,
};

fn lessRanked(_: void, a: RankedSymbol, b: RankedSymbol) bool {
    if (a.tier != b.tier) return a.tier < b.tier;
    if (a.sym.name.len != b.sym.name.len) return a.sym.name.len < b.sym.name.len;
    return std.mem.lessThan(u8, a.sym.name, b.sym.name);
}

pub fn completeArgContext(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, offset: usize) !types.ResponseMessage {
    _ = source;
    _ = offset;
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"isIncomplete\":true,\"items\":[");
    var first = true;

    // Local variables in scope
    const fstmt = self.cachedStmt("SELECT id FROM files WHERE path = ?") catch null;
    if (fstmt) |fs| {
        defer fs.reset();
        fs.bind_text(1, path);
        if (fs.step() catch false) {
            const fid = fs.column_int(0);
            const cursor_line: i64 = @intCast(line + 1);
            const lv_stmt = self.cachedStmt("SELECT DISTINCT name, type_hint FROM local_vars WHERE file_id=? AND line<=? ORDER BY line DESC LIMIT 50") catch null;
            if (lv_stmt) |lv| {
                defer lv.reset();
                lv.bind_int(1, fid);
                lv.bind_int(2, cursor_line);
                while (lv.step() catch false) {
                    if (!first) try w.writeByte(',');
                    first = false;
                    const lname = lv.column_text(0);
                    const ltype = lv.column_text(1);
                    try w.writeAll("{\"label\":");
                    try writeEscapedJson(w, lname);
                    try w.writeAll(",\"kind\":6,\"sortText\":\"0_");
                    try writeEscapedJsonContent(w, lname);
                    try w.writeByte('"');
                    if (ltype.len > 0) {
                        try w.writeAll(",\"detail\":\"");
                        try writeEscapedJsonContent(w, ltype);
                        try w.writeByte('"');
                    }
                    try w.writeByte('}');
                }
            }
        }
    }

    // Then global symbols (methods, classes, constants). Hot path: serve
    // first 200 from the in-mem index using pre-rendered bodies.
    var served_from_hot = false;
    if (self.hot_index_enabled.load(.monotonic)) {
        self.hot_mu.lockUncancelable(std.Options.debug_io);
        defer self.hot_mu.unlock(std.Options.debug_io);
        if (self.hot.load(.acquire)) |hot| {
            var count_h: usize = 0;
            for (hot.sorted_by_name) |sym| {
                if (count_h >= 200) break;
                if (sym.name.len == 0) continue;
                switch (sym.kind) {
                    .def, .classdef, .class_, .module, .constant => {},
                    else => continue,
                }
                const pre_body = hot.lookupPreCompletion(sym.name) orelse continue;
                if (!first) try w.writeByte(',');
                first = false;
                count_h += 1;
                try w.writeAll(pre_body);
                try w.writeByte('}');
            }
            served_from_hot = count_h > 0;
        }
    }
    if (!served_from_hot) {
        const stmt = self.cachedStmt(
            \\SELECT DISTINCT name, kind FROM symbols WHERE kind IN ('def','classdef','class','module','constant') ORDER BY length(name), name LIMIT 200
        ) catch null;
        if (stmt) |s| {
            defer s.reset();
            while (s.step() catch false) {
                if (!first) try w.writeByte(',');
                first = false;
                const cname = s.column_text(0);
                const ckind_str = s.column_text(1);
                const ckind_num: u8 = if (std.mem.eql(u8, ckind_str, "class")) 7 else if (std.mem.eql(u8, ckind_str, "module")) 9 else if (std.mem.eql(u8, ckind_str, "def") or std.mem.eql(u8, ckind_str, "classdef")) 3 else if (std.mem.eql(u8, ckind_str, "constant")) 21 else 1;
                try w.writeAll("{\"label\":");
                try writeEscapedJson(w, cname);
                try w.print(",\"kind\":{d},\"sortText\":\"1_", .{ckind_num});
                try writeEscapedJsonContent(w, cname);
                try w.writeAll("\"}");
            }
        }
    }

    try w.writeAll("]}");
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn completeAllSymbols(self: *Server, msg: types.RequestMessage) !types.ResponseMessage {
    // Hot-index fast path: empty-word completion fires on every keystroke at
    // line starts. Skip the 500-row SQL scan + per-row format when the in-mem
    // index is available.
    if (self.hot_index_enabled.load(.monotonic)) {
        self.hot_mu.lockUncancelable(std.Options.debug_io);
        defer self.hot_mu.unlock(std.Options.debug_io);
        if (self.hot.load(.acquire)) |hot| {
            var items_aw_hot = std.Io.Writer.Allocating.init(self.alloc);
            const wh = &items_aw_hot.writer;
            var first_h = true;
            var count_h: usize = 0;
            for (hot.sorted_by_name) |sym| {
                if (count_h >= 500) break;
                if (sym.name.len == 0) continue;
                switch (sym.kind) {
                    .def, .classdef, .class_, .module, .constant => {},
                    else => continue,
                }
                const pre_body = hot.lookupPreCompletion(sym.name) orelse continue;
                if (!first_h) try wh.writeByte(',');
                first_h = false;
                count_h += 1;
                try wh.writeAll(pre_body);
                try wh.writeByte('}');
            }
            const items_h = try items_aw_hot.toOwnedSlice();
            defer self.alloc.free(items_h);
            var aw_h = std.Io.Writer.Allocating.init(self.alloc);
            const w_h = &aw_h.writer;
            try w_h.writeAll(if (count_h >= 500) "{\"isIncomplete\":true,\"items\":[" else "{\"isIncomplete\":false,\"items\":[");
            try w_h.writeAll(items_h);
            try w_h.writeAll("]}");
            if (count_h > 0) {
                return types.ResponseMessage{
                    .id = msg.id,
                    .result = null,
                    .raw_result = try aw_h.toOwnedSlice(),
                    .@"error" = null,
                };
            }
            aw_h.deinit();
        }
    }

    const stmt2 = try self.cachedStmt(
        \\SELECT DISTINCT name, kind FROM symbols ORDER BY length(name), name LIMIT 500
    );
    defer stmt2.reset();
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

pub fn completeGeneral(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, character: u32, word: []const u8, offset: usize) !types.ResponseMessage {
    const pattern = try buildQueryPattern(self.alloc, word);
    defer self.alloc.free(pattern);
    const prefix_pattern = try buildPrefixPattern(self.alloc, word);
    defer self.alloc.free(prefix_pattern);

    var seen_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer seen_arena.deinit();
    var seen = std.StringHashMap(void).init(seen_arena.allocator());

    var items_aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &items_aw.writer;
    var first = true;
    var symbol_count: usize = 0;

    const want_hot = self.hot_index_enabled.load(.monotonic) and word.len > 0;
    if (want_hot) self.hot_mu.lockUncancelable(std.Options.debug_io);
    defer if (want_hot) self.hot_mu.unlock(std.Options.debug_io);
    const hot_opt = if (want_hot) self.hot.load(.acquire) else null;
    const use_hot = hot_opt != null;
    if (use_hot) {
        const hot = hot_opt.?;
        var ranked = std.ArrayList(RankedSymbol).empty;
        defer ranked.deinit(self.alloc);
        // HotSymbol names are arena-stable until rebuildHotIndex, and we hold
        // hot_mu across this loop — safe to key `seen` directly on the slice.
        for (hot.lookupPrefix(word)) |sym| {
            if (sym.name.len == 0) continue;
            if (seen.contains(sym.name)) continue;
            try seen.put(sym.name, {});
            try ranked.append(self.alloc, .{ .sym = sym, .tier = 0 });
        }
        // Substring fallback runs only when prefix scan came back thin.
        // Linear over `sorted_by_name` (~10k entries on a Mastodon-size repo)
        // is the dominant cost in `micro comp`; skip it when prefix already
        // yielded enough candidates to fill the 200-item response cap.
        if (word.len > 3 and ranked.items.len < 50) {
            var sub_buf = std.ArrayList(hot_index_mod.HotSymbol).empty;
            defer sub_buf.deinit(self.alloc);
            try hot.appendSubstringMatches(word, &sub_buf, self.alloc);
            for (sub_buf.items) |sym| {
                if (sym.name.len == 0) continue;
                if (seen.contains(sym.name)) continue;
                try seen.put(sym.name, {});
                try ranked.append(self.alloc, .{ .sym = sym, .tier = 1 });
            }
        }
        // Subsequence/camelCase fallback when prefix+substring are still thin, so
        // "abc" can surface "ActivateBlockController". Tier 2 → sorts after exact/
        // prefix/substring; the client's own filterText match decides final ranking.
        if (word.len > 2 and ranked.items.len < 25) {
            var seq_buf = std.ArrayList(hot_index_mod.HotSymbol).empty;
            defer seq_buf.deinit(self.alloc);
            try hot.appendSubsequenceMatches(word, &seq_buf, self.alloc);
            for (seq_buf.items) |sym| {
                if (sym.name.len == 0) continue;
                if (seen.contains(sym.name)) continue;
                try seen.put(sym.name, {});
                try ranked.append(self.alloc, .{ .sym = sym, .tier = 2 });
            }
        }
        const had_substring_tier = blk: {
            for (ranked.items) |r| if (r.tier != 0) break :blk true;
            break :blk false;
        };
        if (had_substring_tier) std.mem.sort(RankedSymbol, ranked.items, {}, lessRanked);
        const cap = @min(ranked.items.len, @as(usize, 200));
        const te_start_char = @as(u32, @intCast(character)) -| @as(u32, @intCast(word.len));
        for (ranked.items[0..cap]) |entry| {
            const sym = entry.sym;
            if (!first) try w.writeByte(',');
            first = false;
            symbol_count += 1;

            const is_exact = std.mem.eql(u8, sym.name, word);
            // Fast path: pre-rendered body baked the non-exact sortText prefix.
            // Exact-match needs the `0_0_` etc. tier — fall through to dynamic.
            const pre_body = if (is_exact) null else hot.lookupPreCompletion(sym.name);
            if (pre_body) |body| {
                try w.writeAll(body);
                try w.print(",\"textEdit\":{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":", .{
                    line, te_start_char, line, character,
                });
                try writeEscapedJson(w, sym.name);
                try w.writeByte('}');
                try w.writeByte('}');
                continue;
            }

            const sig: []const u8 = sym.params_sig orelse "";
            const doc: []const u8 = sym.doc orelse "";
            const kind_str = kindStr(sym.kind);
            const kind_num: u8 = kindNum(sym.kind);
            try w.writeAll("{\"label\":");
            try writeEscapedJson(w, sym.name);
            try w.print(",\"kind\":{d},\"detail\":\"(", .{kind_num});
            if ((sym.kind == .def or sym.kind == .classdef) and sig.len > 0) {
                try writeEscapedJsonContent(w, sig);
            } else {
                try writeEscapedJsonContent(w, kind_str);
            }
            try w.writeAll(")\"");
            const is_deprecated = std.mem.startsWith(u8, doc, "**Deprecated:**");
            const sort_prefix: []const u8 = if (is_deprecated) "8_" else switch (sym.kind) {
                .def, .classdef => if (is_exact) "0_0_" else "0_1_",
                .class_, .module => if (is_exact) "1_0_" else "1_1_",
                else => if (is_exact) "2_0_" else "2_1_",
            };
            try w.writeAll(",\"sortText\":\"");
            try writeEscapedJsonContent(w, sort_prefix);
            try writeEscapedJsonContent(w, sym.name);
            try w.writeByte('"');
            try w.writeAll(",\"filterText\":\"");
            try writeEscapedJsonContent(w, sym.name);
            try w.writeByte('"');
            if (sym.kind == .def or sym.kind == .classdef) {
                try w.writeAll(",\"commitCharacters\":[\"(\"]");
            }
            if ((sym.kind == .def or sym.kind == .classdef) and sig.len > 0) {
                writeInsertTextSnippet(w, sym.name, sig) catch {};
            }
            if (doc.len > 0) {
                try w.writeAll(",\"documentation\":{\"kind\":\"markdown\",\"value\":");
                try writeEscapedJson(w, doc);
                try w.writeByte('}');
            }
            try w.print(",\"textEdit\":{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":", .{
                line, te_start_char, line, character,
            });
            try writeEscapedJson(w, sym.name);
            try w.writeByte('}');
            try w.writeByte('}');
        }
    }
    // Fall through to SQL when hot was unavailable, or when use_hot returned
    // zero items — the in-memory hot index can be empty during cold start
    // (warmup builds it from an empty DB before the bg scan completes), and
    // we'd otherwise return an empty completion list while the DB already
    // has the just-indexed-via-didOpen rows.
    if (!use_hot or symbol_count == 0) {
        const stmt = try self.cachedStmt(
            \\SELECT s.name, s.kind,
            \\  (SELECT GROUP_CONCAT(
            \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
            \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
            \\    ELSE p.name END, ', ')
            \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position),
            \\  s.doc
            \\FROM symbols s WHERE s.name LIKE ? ESCAPE '\'
            \\ORDER BY CASE WHEN s.name LIKE ? ESCAPE '\' THEN 0 ELSE 1 END, length(s.name), s.name LIMIT 200
        );
        defer stmt.reset();
        stmt.bind_text(1, pattern);
        stmt.bind_text(2, prefix_pattern);
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
            // Deprecation-aware sort: push deprecated symbols after all other items.
            // Exact-name boost: float exact-match to the top of its tier while preserving tier prefix.
            const is_deprecated = std.mem.startsWith(u8, doc, "**Deprecated:**");
            const is_exact = word.len > 0 and std.mem.eql(u8, name, word);
            const sort_prefix: []const u8 = if (is_deprecated) "8_" else if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) (if (is_exact) "0_0_" else "0_1_") else if (std.mem.eql(u8, kind_str, "class") or std.mem.eql(u8, kind_str, "module")) (if (is_exact) "1_0_" else "1_1_") else (if (is_exact) "2_0_" else "2_1_");
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
    }
    const truncated = symbol_count >= 200;

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

    const fc_stmt = try self.cachedStmt("SELECT id FROM files WHERE path = ?");
    defer fc_stmt.reset();
    fc_stmt.bind_text(1, path);
    if (try fc_stmt.step()) {
        const fid = fc_stmt.column_int(0);
        const lv_stmt = try self.cachedStmt("SELECT DISTINCT name, type_hint FROM local_vars WHERE file_id = ? AND name LIKE ? ESCAPE '\\'");
        defer lv_stmt.reset();
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
        const kp_q = self.cachedStmt("SELECT p.name FROM params p JOIN symbols s ON p.symbol_id=s.id WHERE s.name=? AND s.kind='def' AND p.kind='keyword' ORDER BY p.position LIMIT 20") catch break :kw_params_detect;
        defer kp_q.reset();
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
