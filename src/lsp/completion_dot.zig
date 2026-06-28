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
const lit_recv = @import("literal_receiver.zig");

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

// Camelize a snake_case identifier into a constant candidate (`status_pin` →
// `StatusPin`, `account` → `Account`). Returns null on empty/overflow. Used only
// as a completion-time type guess — never persisted.
fn camelizeIdent(name: []const u8, buf: []u8) ?[]const u8 {
    if (name.len == 0) return null;
    var len: usize = 0;
    var cap_next = true;
    for (name) |ch| {
        if (ch == '_') {
            cap_next = true;
            continue;
        }
        if (len >= buf.len) return null;
        buf[len] = if (cap_next) std.ascii.toUpper(ch) else ch;
        cap_next = false;
        len += 1;
    }
    if (len == 0) return null;
    return buf[0..len];
}

// Element-returning accessors on a homogeneous collection (`Array[T]`/`Set[T]`):
// `arr.first` / `arr.sample` / `arr.pop` … yield an element of type T. Index access
// (`arr[0]`) is handled separately at the call site.
fn isElementReturningMethod(method: []const u8) bool {
    const names = [_][]const u8{
        "first", "last",   "sample", "pop", "shift", "min",  "max",
        "find",  "detect", "fetch",  "dig", "at",    "take", "[]",
    };
    for (names) |n| {
        if (std.mem.eql(u8, method, n)) return true;
    }
    return false;
}

// Base class of a (possibly parameterized) type. The indexer represents an array
// of T as the bracket-prefixed `[T]` (AR plural queries, array literals), whose
// base class is Array. Kept local to completion so global extractBaseClass — used
// by diagnostics — is untouched.
fn baseClassOf(type_str: []const u8) []const u8 {
    const t = std.mem.trim(u8, type_str, " \t");
    if (t.len > 0 and t[0] == '[') return "Array";
    return extractBaseClass(t);
}

// Element/value type of a parameterized collection: `Array[User]`→`User`,
// `Hash[Symbol,User]`→`User` (the value side). Returns "" when not parameterized.
fn collectionElementType(type_str: []const u8) []const u8 {
    const open = std.mem.indexOfScalar(u8, type_str, '[') orelse return "";
    const close = std.mem.lastIndexOfScalar(u8, type_str, ']') orelse return "";
    if (close <= open + 1) return "";
    const inner = std.mem.trim(u8, type_str[open + 1 .. close], " \t");
    if (std.mem.lastIndexOfScalar(u8, inner, ',')) |comma| {
        return std.mem.trim(u8, inner[comma + 1 ..], " \t");
    }
    return inner;
}

// Return type of `method` invoked on an instance of `class`, consulting the hot
// index, the persisted symbols table, then the stdlib map. For a parameterized
// collection (`Array[User]`) an element-returning accessor yields the element
// type. Returned slice is owned by the caller (or null).
fn returnTypeOnClass(self: *Server, method: []const u8, class: []const u8) ?[]u8 {
    const resolved = baseClassOf(class);
    if (resolved.len == 0) return null;
    // `Const.new` → an instance of Const (constructor inference through a chain).
    if (std.mem.eql(u8, method, "new") and std.ascii.isUpper(resolved[0])) {
        return self.alloc.dupe(u8, resolved) catch null;
    }
    if (extractGenericElement(class)) |elem| {
        if (isElementReturningMethod(method)) return self.alloc.dupe(u8, elem) catch null;
    }
    if (hotCrossFileReturnType(self, method, resolved)) |rt| return rt;
    // A method-body return type is stored as a bare constant (`B`) while parent_name
    // is qualified (`Chain::B`); the `LIKE '%::'||?2` clause lets the bare class name
    // match the qualified owner so chains resolve across namespaces.
    const ret_stmt = self.cachedStmt(
        \\SELECT return_type FROM symbols WHERE name=?1 AND kind IN ('def','association','scope') AND return_type IS NOT NULL
        \\  AND (parent_name=?2 OR parent_name LIKE '%::'||?2 OR (parent_name IS NULL AND file_id IN (
        \\    SELECT file_id FROM symbols WHERE kind IN ('class','module')
        \\      AND (name=?2 OR name LIKE '%::'||?2)))) LIMIT 1
    ) catch return null;
    defer ret_stmt.reset();
    ret_stmt.bind_text(1, method);
    ret_stmt.bind_text(2, resolved);
    if (ret_stmt.step() catch false) {
        const cc = ret_stmt.column_text(0);
        if (cc.len > 0) return self.alloc.dupe(u8, cc) catch null;
    }
    if (indexer.lookupStdlibReturn(resolved, method)) |rt| return self.alloc.dupe(u8, rt) catch null;
    // attr_reader/accessor: a method with no recorded return type whose name matches
    // an instance variable carrying an inferred type yields that type. Reuses the
    // already-indexed class-scoped ivar types, so there is no indexer ordering
    // dependency (attrs are declared before ivar assignments are visited).
    {
        const cid = self.cachedStmt("SELECT id FROM symbols WHERE kind IN ('class','module') AND (name=?1 OR name LIKE '%::'||?1) ORDER BY length(name) LIMIT 1") catch return null;
        defer cid.reset();
        cid.bind_text(1, resolved);
        if (cid.step() catch false) {
            const class_id = cid.column_int(0);
            const ivt = self.cachedStmt("SELECT type_hint FROM local_vars WHERE class_id=? AND name=? AND type_hint IS NOT NULL LIMIT 1") catch return null;
            defer ivt.reset();
            ivt.bind_int(1, class_id);
            ivt.bind_text(2, method);
            if (ivt.step() catch false) {
                const t = ivt.column_text(0);
                if (t.len > 0) return self.alloc.dupe(u8, t) catch null;
            }
        }
    }
    return null;
}

// Resolve the type of a receiver-chain BASE token (`self` / `@ivar` / `Const` /
// local var / method param). Used as the seed for the left→right chain fold.
fn resolveChainBaseType(self: *Server, file_id: i64, word: []const u8, cursor_line_db: i64) !?[]u8 {
    if (word.len == 0) return null;
    if (std.mem.eql(u8, word, "self")) {
        const s = try self.cachedStmt("SELECT name FROM symbols WHERE file_id=? AND kind IN ('class','module') AND line<=? ORDER BY line DESC LIMIT 1");
        defer s.reset();
        s.bind_int(1, file_id);
        s.bind_int(2, cursor_line_db);
        if (try s.step()) {
            const n = s.column_text(0);
            if (n.len > 0) return try self.alloc.dupe(u8, n);
        }
        return null;
    }
    if (word[0] == '@') {
        const cls = try self.cachedStmt("SELECT id FROM symbols WHERE file_id=? AND kind IN ('class','module') AND line<=? ORDER BY line DESC LIMIT 1");
        defer cls.reset();
        cls.bind_int(1, file_id);
        cls.bind_int(2, cursor_line_db);
        if (try cls.step()) {
            const class_id = cls.column_int(0);
            const iv = try self.cachedStmt("SELECT type_hint FROM local_vars WHERE class_id=? AND name=? AND type_hint IS NOT NULL LIMIT 1");
            defer iv.reset();
            iv.bind_int(1, class_id);
            iv.bind_text(2, word[1..]);
            if (try iv.step()) {
                const t = iv.column_text(0);
                if (t.len > 0) return try self.alloc.dupe(u8, t);
            }
        }
        return null;
    }
    if (std.ascii.isUpper(word[0])) return try self.alloc.dupe(u8, word);
    // local var (same SQL as completeDot's th_stmt — only reached on the !th_hit
    // chain branch, where th_stmt's row is never consumed, so reuse is safe).
    {
        const lv = try self.cachedStmt("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1");
        defer lv.reset();
        lv.bind_int(1, file_id);
        lv.bind_text(2, word);
        lv.bind_int(3, cursor_line_db);
        if (try lv.step()) {
            const t = lv.column_text(0);
            if (t.len > 0) return try self.alloc.dupe(u8, t);
        }
    }
    // method param with an RBS/Sorbet/YARD type hint
    const def_stmt = try self.cachedStmt("SELECT id FROM symbols WHERE file_id=? AND kind='def' AND line<=? ORDER BY line DESC LIMIT 1");
    defer def_stmt.reset();
    def_stmt.bind_int(1, file_id);
    def_stmt.bind_int(2, cursor_line_db);
    if (try def_stmt.step()) {
        const def_id = def_stmt.column_int(0);
        const pstmt = try self.cachedStmt("SELECT type_hint FROM params WHERE symbol_id=? AND name=? AND type_hint IS NOT NULL LIMIT 1");
        defer pstmt.reset();
        pstmt.bind_int(1, def_id);
        pstmt.bind_text(2, word);
        if (try pstmt.step()) {
            const pt = pstmt.column_text(0);
            if (pt.len > 0) return try self.alloc.dupe(u8, pt);
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
    // Index access: `arr[0].` / `hash[:k].` — the char before the dot is ']'.
    // Resolve the collection receiver and complete on its element/value type.
    // A ']' immediately before the dot unambiguously marks index access, regardless
    // of what extractQualifiedName scavenged to the left of it.
    var index_element = false;
    if (recv_offset < source.len and source[recv_offset] == ']') {
        var depth: i32 = 0;
        var p = recv_offset;
        var found_open = false;
        while (true) {
            const ch = source[p];
            if (ch == ']') {
                depth += 1;
            } else if (ch == '[') {
                depth -= 1;
                if (depth == 0) {
                    found_open = true;
                    break;
                }
            }
            if (p == 0) break;
            p -= 1;
        }
        if (found_open and p > 0) {
            var coll_off = p - 1;
            while (coll_off > 0 and (source[coll_off] == ' ' or source[coll_off] == '\t')) : (coll_off -= 1) {}
            const coll = extractQualifiedName(source, coll_off);
            if (coll.len > 0) {
                recv_word = coll;
                recv_offset = coll_off;
                index_element = true;
            }
        }
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
                    // Literal outer receiver (`1.day`, `"s".upcase`, `[..].first`): type
                    // recv_word's return on the literal's class. `extractLiteralReceiver`
                    // returns null for real identifiers/constants, so this only fires on an
                    // actual literal; it must run BEFORE the multi-segment block (a numeric
                    // base reads back as the "identifier" `1` and would mis-seed the fold).
                    // Folds with the stdlib map (`Integer.day` → Duration).
                    if (chain_class_buf == null) {
                        if (lit_recv.extractLiteralReceiver(source, outer_offset + 1)) |lit| {
                            if (lit_recv.classifyLiteralType(lit)) |lt| {
                                chain_class_buf = returnTypeOnClass(self, recv_word, lt);
                            }
                        }
                    }
                    if (chain_class_buf == null and outer_word.len > 0) {
                        // Multi-level chain: collect the dot-separated identifier
                        // segments left of recv_word (rightmost first), resolve the
                        // base type, then fold method return types left→right through
                        // each segment and finally recv_word. Arg-free idents only —
                        // a paren/bracket between links stops the leftward walk, so a
                        // chain carrying call args degrades to no resolution rather
                        // than mis-resolving.
                        var segs: [8][]const u8 = undefined;
                        var nseg: usize = 0;
                        var seg_off = outer_offset;
                        while (nseg < segs.len) {
                            const w = extractQualifiedName(source, seg_off);
                            if (w.len == 0) break;
                            segs[nseg] = w;
                            nseg += 1;
                            var s = seg_off;
                            while (s > 0 and isRubyIdent(source[s - 1])) s -= 1;
                            while (s >= 2 and source[s - 1] == ':' and source[s - 2] == ':') {
                                var ns = s - 2;
                                while (ns > 0 and isRubyIdent(source[ns - 1])) ns -= 1;
                                if (ns == s - 2) break;
                                s = ns;
                            }
                            if (s < 1 or source[s - 1] != '.') break;
                            var next_off = s - 2;
                            if (next_off > 0 and source[next_off] == '&') {
                                if (next_off < 1) break;
                                next_off -= 1;
                            }
                            if (next_off == 0 and !isRubyIdent(source[0])) break;
                            seg_off = next_off;
                        }
                        if (nseg > 0) {
                            var cur_t: ?[]u8 = try resolveChainBaseType(self, fdc_id, segs[nseg - 1], cursor_line_db);
                            var i = nseg - 1;
                            while (i > 0 and cur_t != null) {
                                i -= 1;
                                const next_t = returnTypeOnClass(self, segs[i], cur_t.?);
                                self.alloc.free(cur_t.?);
                                cur_t = next_t;
                            }
                            if (cur_t) |ct| {
                                chain_class_buf = returnTypeOnClass(self, recv_word, ct);
                                self.alloc.free(ct);
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
            // Method/keyword parameter receiver: `def f(user: User); user.` —
            // params carry type_hint (RBS/Sorbet sigs) but never land in local_vars.
            if (chain_class_buf == null and !th_hit and recv_word.len > 0 and
                recv_word[0] != '@' and !std.ascii.isUpper(recv_word[0]) and
                !std.mem.eql(u8, recv_word, "self"))
            {
                const def_stmt = try self.cachedStmt("SELECT id FROM symbols WHERE file_id=? AND kind='def' AND line<=? ORDER BY line DESC LIMIT 1");
                defer def_stmt.reset();
                def_stmt.bind_int(1, fdc_id);
                def_stmt.bind_int(2, cursor_line_db);
                if (try def_stmt.step()) {
                    const def_id = def_stmt.column_int(0);
                    const param_stmt = try self.cachedStmt("SELECT type_hint FROM params WHERE symbol_id=? AND name=? AND type_hint IS NOT NULL LIMIT 1");
                    defer param_stmt.reset();
                    param_stmt.bind_int(1, def_id);
                    param_stmt.bind_text(2, recv_word);
                    if (try param_stmt.step()) {
                        const pt = param_stmt.column_text(0);
                        if (pt.len > 0) chain_class_buf = try self.alloc.dupe(u8, pt);
                    }
                }
            }

            // Bare-constant alias marker: a local typed `Foo.class` (from `x = Foo`)
            // holds the class object, so complete its singleton/class methods like a
            // constant receiver. Strip the marker and route through the constant path.
            var force_singleton = false;
            if (th_hit) {
                const raw_th = th_stmt.column_text(0);
                if (std.mem.endsWith(u8, raw_th, ".class")) {
                    force_singleton = true;
                    if (chain_class_buf) |cc| self.alloc.free(cc);
                    chain_class_buf = try self.alloc.dupe(u8, raw_th[0 .. raw_th.len - ".class".len]);
                }
            }
            const is_constant_recv = force_singleton or (recv_word.len > 0 and std.ascii.isUpper(recv_word[0]));
            if (chain_class_buf == null and is_constant_recv and !index_element) {
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

            // Route-helper proxy (`spree.admin_orders_path`, `main_app.root_url`): an
            // engine/url-helper proxy whose `*_path`/`*_url` methods are generated by
            // Rails routing and exist in no source file. The routes table already holds
            // every synthesized helper_name (populated by routes.zig, used by
            // go-to-def); surface them as completions. Completion-only.
            if (chain_class_buf == null and !th_hit and !is_constant_recv and !index_element and
                self.has_rails.load(.monotonic) and
                (std.mem.eql(u8, recv_word, "spree") or std.mem.eql(u8, recv_word, "main_app")))
            {
                var aw_rt = std.Io.Writer.Allocating.init(self.alloc);
                const wr = &aw_rt.writer;
                try wr.writeAll("{\"isIncomplete\":false,\"items\":[");
                var rt_first = true;
                if (self.cachedStmt("SELECT DISTINCT helper_name FROM routes WHERE helper_name IS NOT NULL AND helper_name <> ''")) |rs| {
                    defer rs.reset();
                    while (rs.step() catch false) {
                        const helper = rs.column_text(0);
                        if (helper.len == 0) continue;
                        inline for (.{ "_path", "_url" }) |suffix| {
                            if (!rt_first) try wr.writeByte(',');
                            rt_first = false;
                            try wr.writeAll("{\"label\":\"");
                            try writeEscapedJsonContent(wr, helper);
                            try wr.writeAll(suffix);
                            try wr.writeAll("\",\"kind\":3,\"detail\":\"(route)\",\"sortText\":\"1_");
                            try writeEscapedJsonContent(wr, helper);
                            try wr.writeAll("\"}");
                        }
                    }
                } else |_| {}
                try wr.writeAll("]}");
                return types.ResponseMessage{
                    .id = msg.id,
                    .result = null,
                    .raw_result = try aw_rt.toOwnedSlice(),
                    .@"error" = null,
                };
            }

            // Framework receiver (Rails): params/request/cookies/session/… are
            // gem-typed method calls absent from the index, so they resolve to no
            // class. Emit their curated member set. A real local of the same name
            // resolves via type_hint first (th_hit) and never reaches here, so plain
            // Ruby is unaffected; gated on has_rails so non-Rails projects opt out.
            if (chain_class_buf == null and !th_hit and !is_constant_recv and !index_element and
                self.has_rails.load(.monotonic) and c_common.isFrameworkReceiver(recv_word))
            {
                var aw_fw = std.Io.Writer.Allocating.init(self.alloc);
                const wf = &aw_fw.writer;
                try wf.writeAll("{\"isIncomplete\":false,\"items\":[");
                var fw_first = true;
                try c_common.addFrameworkCompletions(wf, recv_word, &fw_first, line, character);
                try wf.writeAll("]}");
                return types.ResponseMessage{
                    .id = msg.id,
                    .result = null,
                    .raw_result = try aw_fw.toOwnedSlice(),
                    .@"error" = null,
                };
            }

            // Last-resort, COMPLETION-ONLY type guess: an untyped local/param named
            // like a class (`account` → Account, `status_pin` → StatusPin) is, in
            // idiomatic Ruby/Rails, usually an instance of it. ~80% of real receivers
            // carry no inferable type; this recovers member completion on the common
            // convention. It is never written to local_vars, so diagnostics / refs /
            // hover are unaffected and cannot gain a false positive from a wrong guess.
            if (chain_class_buf == null and !th_hit and !is_constant_recv and !index_element and
                recv_word.len > 0 and recv_word[0] != '@' and recv_word[0] != '$' and
                !std.mem.eql(u8, recv_word, "self") and std.mem.indexOf(u8, recv_word, "::") == null)
            {
                var cbuf: [128]u8 = undefined;
                if (camelizeIdent(recv_word, &cbuf)) |cand| {
                    const gstmt = try self.cachedStmt(
                        \\SELECT name FROM symbols WHERE kind IN ('class','module')
                        \\  AND (name = ?1 OR name LIKE '%::' || ?1)
                        \\ORDER BY CASE WHEN name = ?1 THEN 0 ELSE 1 END, length(name) LIMIT 1
                    );
                    defer gstmt.reset();
                    gstmt.bind_text(1, cand);
                    if (try gstmt.step()) {
                        const gn = gstmt.column_text(0);
                        if (gn.len > 0) chain_class_buf = try self.alloc.dupe(u8, gn);
                    }
                }
            }
            // A chain/return-type result is stored as a bare constant (`C`) while
            // member lookup keys on the qualified parent_name (`Chn::C`). Qualify a
            // bare chain_class_buf to its stored fully-qualified name.
            if (!force_singleton and !index_element) {
                if (chain_class_buf) |cc| {
                    if (cc.len > 0 and std.ascii.isUpper(cc[0]) and std.mem.indexOf(u8, cc, "::") == null) {
                        const qcstmt = try self.cachedStmt(
                            \\SELECT name FROM symbols WHERE kind IN ('class','module')
                            \\  AND (name=?1 OR name LIKE '%::'||?1)
                            \\ORDER BY CASE WHEN name=?1 THEN 0 ELSE 1 END, length(name) LIMIT 1
                        );
                        defer qcstmt.reset();
                        qcstmt.bind_text(1, cc);
                        if (try qcstmt.step()) {
                            const qn = qcstmt.column_text(0);
                            if (qn.len > 0 and !std.mem.eql(u8, qn, cc)) {
                                const dup = try self.alloc.dupe(u8, qn);
                                self.alloc.free(cc);
                                chain_class_buf = dup;
                            }
                        }
                    }
                }
            }
            const is_self_recv = std.mem.eql(u8, recv_word, "self");
            const class_name_raw: []const u8 = if (force_singleton) (chain_class_buf orelse "") else if (th_hit) th_stmt.column_text(0) else if (chain_class_buf) |cc| cc else "";
            // For index access (`arr[0].`/`hash[:k].`) the receiver's resolved type is
            // the collection; complete on its element (`[T]`/Array[T]→T) or value
            // (Hash[K,V]→V). `ENV["X"]` yields a String (core Ruby, not Rails-gated).
            const class_name = if (index_element)
                (if (std.mem.eql(u8, recv_word, "ENV")) "String" else baseClassOf(collectionElementType(class_name_raw)))
            else
                baseClassOf(class_name_raw);
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
                    const resolved_class = baseClassOf(part_trimmed);
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
                            \\WHERE s.kind IN ('def','association') AND (s.parent_name = ?1 OR s.parent_name = ?3 OR (s.parent_name IS NULL AND s.file_id IN (
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
                            \\WHERE s.kind IN ('def','association') AND (s.parent_name = ?1 OR s.parent_name = ?3 OR (s.parent_name IS NULL AND s.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?2
                            \\))) AND (s.visibility IS NULL OR s.visibility = 'public')
                        ) catch null;
                    defer if (own_stmt_hoisted) |s2| s2.reset();
                    const cls_stmt_hoisted = if (is_constant_recv)
                        self.cachedStmt(
                            \\SELECT s.name, s.doc FROM symbols s
                            \\WHERE s.kind IN ('classdef','scope') AND (s.parent_name = ?1 OR (s.parent_name IS NULL AND s.file_id IN (
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
                        // Schema columns of namespaced engine models (Spree::CreditCard) are
                        // parented to the flat camelized table name (SpreeCreditCard) because
                        // tableNameToModel cannot know the engine's table_name_prefix. Bridge by
                        // also matching the flattened (::-stripped) form of the resolved class.
                        var flat_buf: [256]u8 = undefined;
                        var flat_len: usize = 0;
                        for (current) |ch| {
                            if (ch == ':') continue;
                            if (flat_len >= flat_buf.len) break;
                            flat_buf[flat_len] = ch;
                            flat_len += 1;
                        }
                        own_stmt.bind_text(3, flat_buf[0..flat_len]);
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

                        // Ascend the real superclass: `parent_name` carries the
                        // namespace for nested classes (only top-level classes mirror
                        // the superclass into it), so it would walk the lexical parent
                        // instead of the ancestor. `superclass` is written for every
                        // class, falling back to parent_name when absent.
                        // A class reopened across files (Spree decorates models in many
                        // files) yields several rows; reopens carry no `< Super`, so their
                        // superclass is NULL and COALESCE falls back to the namespace
                        // (parent_name=`Spree`), dead-ending the ancestor walk before
                        // ApplicationRecord and silently dropping the AR base API. Prefer
                        // the row that actually records a superclass.
                        const par_stmt = try self.cachedStmt("SELECT COALESCE(superclass, parent_name) FROM symbols WHERE kind='class' AND name=? AND COALESCE(superclass, parent_name) IS NOT NULL ORDER BY (superclass IS NULL) LIMIT 1");
                        defer par_stmt.reset();
                        par_stmt.bind_text(1, current);
                        if (try par_stmt.step()) {
                            const pname = par_stmt.column_text(0);
                            if (pname.len == 0) break;
                            // Superclasses are written bare (`Base`) while class
                            // symbols/methods are stored fully qualified (`Xf::Base`),
                            // so canonicalize an unqualified ancestor to its stored
                            // name (shortest `%::Base` suffix) before the next step.
                            var next_cur = try ma.dupe(u8, pname);
                            if (std.mem.indexOf(u8, pname, "::") == null) {
                                if (self.cachedStmt(
                                    \\SELECT name FROM symbols WHERE kind IN ('class','module')
                                    \\  AND (name = ?1 OR name LIKE '%::' || ?1)
                                    \\ORDER BY CASE WHEN name = ?1 THEN 0 ELSE 1 END, length(name) LIMIT 1
                                ) catch null) |cs| {
                                    defer cs.reset();
                                    cs.bind_text(1, pname);
                                    if (cs.step() catch false) {
                                        const cn = cs.column_text(0);
                                        if (cn.len > 0) next_cur = try ma.dupe(u8, cn);
                                    }
                                }
                            }
                            current = next_cur;
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
                // Universal Object/Kernel methods: every receiver responds to these,
                // but they live on BasicObject/Kernel/Object which user code never
                // re-declares, so the symbol-table walk never surfaces them. Inject
                // for any resolved receiver (deduped against real members).
                {
                    const universal = [_][]const u8{
                        "nil?",      "is_a?",                 "kind_of?",              "instance_of?", "respond_to?",
                        "tap",       "then",                  "itself",                "freeze",       "frozen?",
                        "dup",       "clone",                 "to_s",                  "inspect",      "hash",
                        "object_id", "send",                  "public_send",           "method",       "methods",
                        "equal?",    "instance_variable_get", "instance_variable_set",
                    };
                    for (universal) |um| {
                        if (seen_names.contains(um)) continue;
                        if (!first_dot) try wd.writeByte(',');
                        first_dot = false;
                        try wd.writeAll("{\"label\":");
                        try writeEscapedJson(wd, um);
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
