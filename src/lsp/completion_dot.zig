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
const type_resolver = @import("type_resolver.zig");
const writeInsertTextSnippet = c_common.writeInsertTextSnippet;
const addStdlibCompletions = c_common.addStdlibCompletions;
const lit_recv = @import("literal_receiver.zig");

fn hotCrossFileReturnType(self: *Server, method_name: []const u8, parent_class: []const u8) ?[]u8 {
    var hg = self.lockHot();
    defer hg.deinit();
    const hot = hg.hot orelse return null;
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

// Resolve a bare/relative class-or-module name to its stored fully-qualified form:
// prefer an exact match, else the shortest `%::Name` suffix. Returns an `alloc`-owned
// dup, or null when no class/module matches. Centralizes the namespaced/flat name
// bridge otherwise open-coded across every receiver-typing path.
fn qualifyClassName(self: *Server, alloc: std.mem.Allocator, bare: []const u8) ?[]u8 {
    if (bare.len == 0) return null;
    const st = self.cachedStmt(
        \\SELECT name FROM symbols WHERE kind IN ('class','module')
        \\  AND (name = ?1 OR name LIKE '%::' || ?1)
        \\ORDER BY CASE WHEN name = ?1 THEN 0 ELSE 1 END, length(name) LIMIT 1
    ) catch return null;
    defer st.reset();
    st.bind_text(1, bare);
    if (st.step() catch false) {
        const n = st.column_text(0);
        if (n.len > 0) return alloc.dupe(u8, n) catch null;
    }
    return null;
}

// Exact-name class lookup (no `%::` suffix fallback). A coincidental suffix match is
// weak — `chat_channel` camelizes to `ChatChannel`, which suffix-matches an unrelated
// page-object `PageObjects::…::ChatChannel` and shadows the real AR model `Chat::Channel`.
// Used to prioritize strong exact matches (flat then namespaced-split) in the guess.
fn qualifyClassExact(self: *Server, alloc: std.mem.Allocator, bare: []const u8) ?[]u8 {
    if (bare.len == 0) return null;
    const st = self.cachedStmt("SELECT name FROM symbols WHERE kind IN ('class','module') AND name = ?1 LIMIT 1") catch return null;
    defer st.reset();
    st.bind_text(1, bare);
    if (st.step() catch false) {
        const n = st.column_text(0);
        if (n.len > 0) return alloc.dupe(u8, n) catch null;
    }
    return null;
}

// When a receiver is a homogeneous collection of an ActiveRecord model (`Array[Order]`
// from a plural query/var), it behaves as a relation: it responds to AR query methods and
// the model's named scopes, not just Enumerable. Returns the element model name when the
// element is AR-shaped (has scopes/associations — excludes `Array[String]` etc.), else null.
fn modelCollectionElement(self: *Server, alloc: std.mem.Allocator, class_name_raw: []const u8) ?[]u8 {
    const elem = collectionElementType(class_name_raw);
    if (elem.len == 0 or !std.ascii.isUpper(elem[0])) return null;
    const st = self.cachedStmt("SELECT 1 FROM symbols WHERE (parent_name=?1 OR parent_name LIKE '%::'||?1) AND kind IN ('scope','association') LIMIT 1") catch return null;
    defer st.reset();
    st.bind_text(1, elem);
    if (st.step() catch false) return alloc.dupe(u8, elem) catch null;
    return null;
}

// The class/module symbol enclosing a cursor position (innermost by line). Returns
// its id, or null when the cursor is at top level. Shared by the `@ivar`/`self`
// receiver-typing branches.
fn enclosingClassId(self: *Server, file_id: i64, cursor_line_db: i64) ?i64 {
    const s = self.cachedStmt("SELECT id FROM symbols WHERE file_id=? AND kind IN ('class','module') AND line<=? ORDER BY line DESC LIMIT 1") catch return null;
    defer s.reset();
    s.bind_int(1, file_id);
    s.bind_int(2, cursor_line_db);
    if (s.step() catch false) return s.column_int(0);
    return null;
}

// Name of the class/module enclosing a cursor position. Returns an `alloc`-owned dup,
// or null at top level.
fn enclosingClassName(self: *Server, alloc: std.mem.Allocator, file_id: i64, cursor_line_db: i64) ?[]u8 {
    const s = self.cachedStmt("SELECT name FROM symbols WHERE file_id=? AND kind IN ('class','module') AND line<=? ORDER BY line DESC LIMIT 1") catch return null;
    defer s.reset();
    s.bind_int(1, file_id);
    s.bind_int(2, cursor_line_db);
    if (s.step() catch false) {
        const n = s.column_text(0);
        if (n.len > 0) return alloc.dupe(u8, n) catch null;
    }
    return null;
}

// Relevance-ranked sortText prefix for a member item. The client re-sorts the whole
// list lexicographically by sortText, so a flat `"0_"+name` collapses every member to
// alphabetical order and buries the likely call deep in a 60-80 item list (measured:
// mastodon membership 0.71 but recall@10 0.21 — the method is present, just not near the
// top). Encoding (ancestor `depth`, source `bucket`, inverted call-`freq`) makes the
// client's own sort surface own-class > mixin > inherited, most-called first. Pure
// reorder: identical item set, no membership change, so precision is untouched.
// Digits keep members inside the legacy `0…` sortText band (below the `1_` synth/stdlib
// items), preserving members-before-synth ordering. NULL-safe: freq 0 sorts last in band.
fn writeSortRank(wd: *std.Io.Writer, local: bool, depth: u8, bucket: u8, freq: u32) !void {
    const inv: u32 = 999999 - @min(freq, 999999);
    // `local` (member defined in the cursor's own file) is the top axis: a method the
    // dev is looking at outranks any inherited/mixed member regardless of depth/freq.
    try wd.print("0{d}{d}{d}{d:0>6}_", .{ @as(u8, if (local) 0 else 1), @min(depth, 9), @min(bucket, 9), inv });
}

// Bounded workspace call-frequency of a method name (idx_refs_name). Capped at 4000 so a
// hot name (`id`, `call`, `name`) can't turn a per-member count into an O(refs) scan on
// the completion path — 4000 differentiates rare vs common enough for ranking.
fn memberFreq(self: *Server, name: []const u8) u32 {
    const st = self.cachedStmt("SELECT COUNT(*) FROM (SELECT 1 FROM refs WHERE name=?1 LIMIT 4000)") catch return 0;
    st.reset();
    st.bind_text(1, name);
    return if (st.step() catch false) @intCast(st.column_int(0)) else 0;
}

// Serialize one method-member completion item (the simple form, no typed-sig detail).
// The comma separator and `first_dot`/`seen_names` bookkeeping stay at the call site
// since they are loop state; this writes only the item object. `detail` is the raw
// detail string (`(def)`, `(def self)`). Shared by the prepend/classdef/mixin emit loops.
// `local`/`depth`/`bucket`/`freq` feed the relevance sortText (see writeSortRank).
fn writeMethodMemberItem(wd: *std.Io.Writer, name: []const u8, doc: []const u8, detail: []const u8, line: u32, character: u32, local: bool, depth: u8, bucket: u8, freq: u32) !void {
    try wd.writeAll("{\"label\":");
    try writeEscapedJson(wd, name);
    try wd.writeAll(",\"kind\":3,\"detail\":\"");
    try writeEscapedJsonContent(wd, detail);
    try wd.writeAll("\",\"sortText\":\"");
    try writeSortRank(wd, local, depth, bucket, freq);
    try writeEscapedJsonContent(wd, name);
    try wd.writeAll("\",\"filterText\":\"");
    try writeEscapedJsonContent(wd, name);
    try wd.writeAll("\",\"commitCharacters\":[\"(\"]");
    if (doc.len > 0) {
        try wd.writeAll(",\"documentation\":\"");
        try writeEscapedJsonContent(wd, doc);
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
    try writeEscapedJsonContent(wd, name);
    try wd.writeAll("\"},\"data\":{\"name\":");
    try writeEscapedJson(wd, name);
    try wd.writeAll("}");
    try wd.writeByte('}');
}

// Tier-0 fallback: reached only when a real `receiver.` was typed but no receiver
// type could be inferred (the `class_name.len==0` seam) — the plain/untyped-Ruby
// case where completion would otherwise return nothing. Emit workspace method names
// ranked by call frequency, prefix-filtered by what the dev has typed after the dot.
// Returns `isIncomplete:true` so the client re-queries per keystroke as the fragment
// grows (a bare dot's global-frequency list is measured near-worthless, so we emit an
// empty incomplete list there and wait for ≥2 typed chars before ranking). Items sit
// in the lowest sortText bucket (9) so they can never outrank a genuinely resolved
// member — this path only fires when there are no resolved members, so precision is
// untouched. kind:3 (method) mirrors resolved members.
fn tier0Fallback(self: *Server, msg: types.RequestMessage, line: u32, character: u32, frag: []const u8) !?types.ResponseMessage {
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const wd = &aw.writer;
    try wd.writeAll("{\"isIncomplete\":true,\"items\":[");
    if (frag.len >= 2) {
        const q = self.cachedStmt(
            \\SELECT s.name, COUNT(r.name) AS freq
            \\FROM (SELECT DISTINCT name FROM symbols WHERE kind='def' AND name LIKE ?1 || '%') s
            \\LEFT JOIN refs r ON r.name = s.name
            \\GROUP BY s.name ORDER BY freq DESC, s.name ASC LIMIT 200
        ) catch null;
        if (q) |st| {
            defer st.reset();
            st.bind_text(1, frag);
            var first = true;
            while (st.step() catch false) {
                const nm = st.column_text(0);
                if (nm.len == 0) continue;
                const freq: u32 = @intCast(st.column_int(1));
                if (!first) try wd.writeByte(',');
                first = false;
                try writeMethodMemberItem(wd, nm, "", "(workspace)", line, character, false, 9, 9, freq);
            }
        }
    }
    try wd.writeAll("]}");
    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
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

// Methods that return the receiver itself (same runtime type), so a chain link
// through one is transparent for type-folding: `reload`/`dup`/`clone`/`freeze`
// (AR + core), `itself`/`tap` (core), `presence` (ActiveSupport, receiver-or-nil).
fn isIdentityReturningMethod(method: []const u8) bool {
    const names = [_][]const u8{ "reload", "dup", "clone", "freeze", "itself", "tap", "presence" };
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
    // Identity / self-returning methods: `reload`/`dup`/`clone`/`freeze`/`itself`/
    // `tap`/`presence` return the receiver unchanged, so a chain link through one keeps
    // the current type (`user.reload.role` → reload is transparent, role resolves on
    // User). Return the FULL `class` (preserving any `[T]` collection shape) so a
    // relation `.dup.each` still yields the element. Very common in specs/AR code.
    if (isIdentityReturningMethod(method)) return self.alloc.dupe(u8, class) catch null;
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
        return enclosingClassName(self, self.alloc, file_id, cursor_line_db);
    }
    if (word[0] == '@') {
        if (enclosingClassId(self, file_id, cursor_line_db)) |class_id| {
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
            // A `Foo.class` hint (e.g. `described_class`) holds the class object: as a
            // chain base it seeds the bare class so a following `.new` folds to an
            // instance. The single-receiver path strips this marker separately.
            if (std.mem.endsWith(u8, t, ".class") and t.len > ".class".len)
                return try self.alloc.dupe(u8, t[0 .. t.len - ".class".len]);
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

// Strip a leading Rails-convention qualifier so a receiver named for its role
// resolves to its model (`source_account`→`account`, `current_user`→`user`). Returns
// the original name when no known prefix matches.
fn stripConventionPrefix(name: []const u8) []const u8 {
    const prefixes = [_][]const u8{
        "current_",  "source_",    "target_",   "default_",    "new_",     "old_",
        "parent_",   "child_",     "original_", "existing_",   "other_",   "next_",
        "previous_", "prev_",      "selected_", "associated_", "related_", "linked_",
        "temp_",     "tmp_",       "saved_",    "persisted_",  "given_",   "the_",
        "from_",     "to_",        "for_",      "by_",         "with_",    "owner_",
        "sender_",   "recipient_", "author_",   "creator_",    "updated_", "remote_",
    };
    for (prefixes) |p| {
        if (name.len > p.len and std.mem.startsWith(u8, name, p)) return name[p.len..];
    }
    return name;
}

// Naive English singularizer for an identifier (`companies`→`company`,
// `accounts`→`account`, `statuses`→`status`). Writes into buf; returns input when
// already singular / on overflow.
fn singularizeIdent(name: []const u8, buf: []u8) []const u8 {
    if (name.len < 2 or buf.len < name.len) return name;
    if (std.mem.endsWith(u8, name, "ies") and name.len > 3) {
        const base = name[0 .. name.len - 3];
        @memcpy(buf[0..base.len], base);
        buf[base.len] = 'y';
        return buf[0 .. base.len + 1];
    }
    inline for (.{ "ses", "xes", "zes", "ches", "shes" }) |suf| {
        if (std.mem.endsWith(u8, name, suf)) {
            const base = name[0 .. name.len - 2]; // drop "es"
            @memcpy(buf[0..base.len], base);
            return buf[0..base.len];
        }
    }
    if (name[name.len - 1] == 's' and name[name.len - 2] != 's') return name[0 .. name.len - 1];
    return name;
}

// Look up the class whose camelized name matches `snake`, exact-or-`%::`-suffix.
// Owned slice or null.
fn lookupClassByCamel(self: *Server, snake: []const u8) ?[]u8 {
    if (snake.len == 0) return null;
    var cbuf: [128]u8 = undefined;
    const cand = camelizeIdent(snake, &cbuf) orelse return null;
    return qualifyClassName(self, self.alloc, cand);
}

// Namespace-split guess: a compound snake identifier whose flat camelization names
// no class may instead name a NAMESPACED class — `chat_message` → `Chat::Message`,
// `direct_message` → `DirectMessage` (flat, already tried) vs `Direct::Message`. Camelize
// each underscore segment and join with `::`, then match the class table exact-or-suffix.
// Only fires as a fallback when the flat forms miss AND the split names a REAL indexed
// class, so it can only ADD a correct completion, never mis-resolve to a phantom class.
fn namespaceSplitClass(self: *Server, recv_word: []const u8) ?[]u8 {
    if (std.mem.indexOfScalar(u8, recv_word, '_') == null) return null;
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    var it = std.mem.splitScalar(u8, recv_word, '_');
    var first = true;
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (!first) {
            if (len + 2 > buf.len) return null;
            buf[len] = ':';
            buf[len + 1] = ':';
            len += 2;
        }
        first = false;
        if (len >= buf.len) return null;
        buf[len] = std.ascii.toUpper(seg[0]);
        len += 1;
        if (len + seg.len - 1 > buf.len) return null;
        @memcpy(buf[len .. len + seg.len - 1], seg[1..]);
        len += seg.len - 1;
    }
    if (len == 0 or first) return null;
    return qualifyClassExact(self, self.alloc, buf[0..len]);
}

// Completion-only receiver-type guess from an identifier, idiomatic-Rails aware:
// tries the name, its singular, and a convention-prefix-stripped form (+ its
// singular) against the class table. Never persisted, so a wrong guess only fails
// to add a completion — it cannot create a diagnostic/refs false positive.
fn guessReceiverClass(self: *Server, recv_word: []const u8) ?[]u8 {
    var sbuf: [128]u8 = undefined;
    const stripped = stripConventionPrefix(recv_word);
    const bases = [_][]const u8{ recv_word, stripped };
    // Strong exact matches FIRST — a coincidental `%::CamelName` suffix (page objects,
    // serializers) must not shadow the real class. Flat exact (`account`→`Account`),
    // then namespaced-split exact (`chat_channel`→`Chat::Message` model, not the
    // `PageObjects::…::ChatChannel` suffix). Only affects compound names whose flat
    // form has no exact class, so plain receivers are unchanged.
    for (bases) |base| {
        var cb: [128]u8 = undefined;
        if (camelizeIdent(base, &cb)) |cand| {
            if (qualifyClassExact(self, self.alloc, cand)) |c| return c;
        }
    }
    if (namespaceSplitClass(self, recv_word)) |c| return c;
    for (bases) |base| {
        // For a PLURAL-looking word, prefer the collection shape: singular class → Array[C].
        // This must run BEFORE the bare match — otherwise `pending_registrations` could match a
        // (rare) plural class name and resolve to a SINGULAR receiver, losing the relation/
        // Enumerable surface (`.all?`/`.map`). Member completion on Array[C] offers Enumerable +
        // the element's scopes instead of scalar C methods.
        const sing = singularizeIdent(base, &sbuf);
        if (!std.mem.eql(u8, sing, base)) {
            if (lookupClassByCamel(self, sing)) |c| {
                defer self.alloc.free(c);
                return std.fmt.allocPrint(self.alloc, "Array[{s}]", .{c}) catch null;
            }
        }
        // Singular word (or plural with no singular class): match the name directly.
        if (lookupClassByCamel(self, base)) |c| return c;
    }
    return null;
}

pub fn completeDot(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, character: u32, offset: usize, word: []const u8) !?types.ResponseMessage {
    var recv_offset = if (offset >= 2) offset - 2 else 0;
    while (recv_offset > 0 and (source[recv_offset] == ' ' or source[recv_offset] == '\t')) : (recv_offset -= 1) {}
    var recv_word = extractQualifiedName(source, recv_offset);
    if (recv_word.len == 0 and recv_offset > 0 and source[recv_offset] == '&') {
        recv_offset = if (recv_offset >= 1) recv_offset - 1 else 0;
        recv_word = extractQualifiedName(source, recv_offset);
    }
    // Global variable receiver: `$redis.` — extractQualifiedName stops at `$`
    // (not an ident char), but globals are indexed under their `$`-prefixed name
    // (handleGlobalVarWrite in visitor_vars.zig). Reattach the sigil so the type_hint
    // lookup below matches. Inert when no typed global exists (falls to guess paths).
    if (recv_word.len > 0) {
        const rw_start = @intFromPtr(recv_word.ptr) - @intFromPtr(source.ptr);
        if (rw_start > 0 and source[rw_start - 1] == '$') {
            recv_word = source[rw_start - 1 .. rw_start + recv_word.len];
        }
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
                if (enclosingClassId(self, fdc_id, cursor_line_db)) |class_id| {
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
                chain_class_buf = enclosingClassName(self, self.alloc, fdc_id, cursor_line_db);
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

            // Implicit-self method/scope/association call as a receiver: inside
            // `class Account`, a bare `prunable_accounts.find_each` / `emails.each`
            // calls an own scope/association/method on self. Resolve its recorded
            // return type on the enclosing class — precise (only fires when that class
            // actually declares the member with a return type), so it beats the naming
            // guess below and never mis-resolves a plain local. Completion-only.
            if (chain_class_buf == null and !th_hit and recv_word.len > 0 and
                recv_word[0] != '@' and recv_word[0] != '$' and !std.ascii.isUpper(recv_word[0]) and
                !std.mem.eql(u8, recv_word, "self") and std.mem.indexOf(u8, recv_word, "::") == null)
            {
                if (enclosingClassName(self, self.alloc, fdc_id, cursor_line_db)) |enc| {
                    defer self.alloc.free(enc);
                    chain_class_buf = returnTypeOnClass(self, recv_word, enc);
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
                    chain_class_buf = qualifyClassName(self, self.alloc, recv_word);
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
                recv_word.len > 0 and recv_word[0] != '$' and
                !std.mem.eql(u8, recv_word, "self") and std.mem.indexOf(u8, recv_word, "::") == null)
            {
                // Strip a leading `@`/`@@`: an instance/class var named after its type
                // (`@order` → Order) is idiomatic Rails and usually instance-typed. Only
                // reached when the ivar has no recorded type_hint (cross-file assignment,
                // e.g. a parent controller's before_action), so real typing still wins.
                var guess_word = recv_word;
                while (guess_word.len > 0 and guess_word[0] == '@') guess_word = guess_word[1..];
                if (guess_word.len > 0) chain_class_buf = guessReceiverClass(self, guess_word);
            }
            // A chain/return-type result is stored as a bare constant (`C`) while
            // member lookup keys on the qualified parent_name (`Chn::C`). Qualify a
            // bare chain_class_buf to its stored fully-qualified name.
            if (!force_singleton and !index_element) {
                if (chain_class_buf) |cc| {
                    if (cc.len > 0 and std.ascii.isUpper(cc[0]) and std.mem.indexOf(u8, cc, "::") == null) {
                        if (qualifyClassName(self, self.alloc, cc)) |qn| {
                            if (!std.mem.eql(u8, qn, cc)) {
                                self.alloc.free(cc);
                                chain_class_buf = qn;
                            } else self.alloc.free(qn);
                        }
                    }
                }
            }
            const is_self_recv = std.mem.eql(u8, recv_word, "self");
            // Lever 1: when an external type checker (Sorbet/Steep) is running, its
            // type for the receiver is authoritative — prefer it over the heuristic
            // th_hit / chain / naming-guess. resolveExternalOracle returns null on
            // every untyped workspace (worker not spawned, or no ≥80-confidence
            // result), so plain-Ruby completion is unchanged and pays no cost. Only
            // a fully-reduced bare class ref is used; residue like `T.untyped` or a
            // union falls through to the existing heuristics (precision-safe).
            var oracle_class_buf: ?[]u8 = null;
            defer if (oracle_class_buf) |o| self.alloc.free(o);
            if (!force_singleton and !index_element and !is_self_recv and
                recv_word.len > 0 and recv_word[0] != '$' and
                (self.sorbet_worker_handle != null or self.steep_worker_handle != null))
            {
                if (type_resolver.resolveExternalOracle(self.alloc, self.queryDb(), recv_word)) |res| {
                    var r = res;
                    defer r.deinit(self.alloc);
                    if (type_resolver.stripWrapper(self.alloc, r.type_str) catch null) |bare| {
                        if (type_resolver.isBareClassRef(bare)) oracle_class_buf = bare else self.alloc.free(bare);
                    }
                }
            }
            const class_name_raw: []const u8 = if (oracle_class_buf) |o| o else if (force_singleton) (chain_class_buf orelse "") else if (th_hit) th_stmt.column_text(0) else if (chain_class_buf) |cc| cc else "";
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
                var is_ar_model = false; // ancestor is ApplicationRecord/ActiveRecord::Base

                // Handle union types: "String | Integer" → query each component
                var union_it = std.mem.splitSequence(u8, class_name, " | ");
                var union_first = true;
                while (union_it.next()) |union_part| {
                    const part_trimmed = std.mem.trim(u8, union_part, " \t");
                    if (part_trimmed.len == 0) continue;
                    var resolved_class = baseClassOf(part_trimmed);
                    if (resolved_class.len == 0) continue;
                    // A bare class name (e.g. a factory-typed `Order`) may be stored
                    // fully-qualified (`Spree::Order`); resolve it so the member walk
                    // finds the real methods instead of an empty/wrong bare class.
                    if (std.mem.indexOf(u8, resolved_class, "::") == null and std.ascii.isUpper(resolved_class[0])) {
                        var qualified = false;
                        if (qualifyClassName(self, ma, resolved_class)) |qn| {
                            resolved_class = qn;
                            qualified = true;
                        }
                        // The bare type names no real class (e.g. a compound factory name
                        // `OrderWithLineItems` from `create(:order_with_line_items)`). Fall
                        // back to the receiver-name heuristic so a mis-typed factory var is
                        // no worse than an untyped one — guarantees no regression.
                        if (!qualified and recv_word.len > 0) {
                            if (guessReceiverClass(self, recv_word)) |g| {
                                resolved_class = ma.dupe(u8, g) catch resolved_class;
                                self.alloc.free(g);
                            }
                        }
                    }
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
                            \\   FROM params p WHERE p.symbol_id=s.id AND p.type_hint IS NOT NULL ORDER BY p.position),
                            \\  s.file_id
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
                            \\   FROM params p WHERE p.symbol_id=s.id AND p.type_hint IS NOT NULL ORDER BY p.position),
                            \\  s.file_id
                            \\FROM symbols s
                            \\WHERE s.kind IN ('def','association') AND (s.parent_name = ?1 OR s.parent_name = ?3 OR (s.parent_name IS NULL AND s.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?2
                            \\))) AND (s.visibility IS NULL OR s.visibility = 'public')
                        ) catch null;
                    defer if (own_stmt_hoisted) |s2| s2.reset();
                    const cls_stmt_hoisted = if (is_constant_recv)
                        self.cachedStmt(
                            \\SELECT s.name, s.doc, s.file_id FROM symbols s
                            \\WHERE s.kind IN ('classdef','scope') AND (s.parent_name = ?1 OR (s.parent_name IS NULL AND s.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=?2
                            \\))) AND (s.visibility IS NULL OR s.visibility = 'public')
                        ) catch null
                    else
                        null;
                    defer if (cls_stmt_hoisted) |s2| s2.reset();
                    // Cursor's own file id: a member defined here is what the dev is
                    // looking at, so it gets the top sortText axis (see writeSortRank).
                    const cursor_file_id: i64 = blk: {
                        const fs = self.cachedStmt("SELECT id FROM files WHERE path=?1 LIMIT 1") catch break :blk -1;
                        fs.reset();
                        fs.bind_text(1, path);
                        break :blk if (fs.step() catch false) fs.column_int(0) else -1;
                    };
                    var depth: u8 = 0;
                    while (depth < 8) : (depth += 1) {
                        if (seen_classes.contains(current)) break;
                        try seen_classes.put(try ma.dupe(u8, current), {});

                        const prep_stmt = try self.cachedStmt(
                            \\SELECT DISTINCT s2.name, s2.doc, s2.file_id FROM symbols s2
                            \\JOIN mixins m ON s2.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=m.module_name
                            \\)
                            \\WHERE m.class_id IN (
                            \\  SELECT id FROM symbols WHERE kind IN ('class','module') AND name=?
                            \\) AND s2.kind IN ('def','association','scope') AND m.kind='prepend'
                        );
                        defer prep_stmt.reset();
                        prep_stmt.bind_text(1, current);
                        while (try prep_stmt.step()) {
                            const mname2 = prep_stmt.column_text(0);
                            if (seen_names.contains(mname2)) continue;
                            try seen_names.put(try ma.dupe(u8, mname2), {});
                            if (!first_dot) try wd.writeByte(',');
                            first_dot = false;
                            try writeMethodMemberItem(wd, mname2, prep_stmt.column_text(1), "(def)", line, character, prep_stmt.column_int(2) == cursor_file_id, depth, 1, memberFreq(self, mname2));
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
                            const freq_own = memberFreq(self, mname2);
                            const local_own = own_stmt.column_int(5) == cursor_file_id;
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
                                try wd.writeAll("\",\"sortText\":\"");
                            } else {
                                try wd.writeAll(",\"kind\":3,\"detail\":\"(def)\",\"sortText\":\"");
                            }
                            try writeSortRank(wd, local_own, depth, 0, freq_own);
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
                                    try writeMethodMemberItem(wd, mname2, cls_stmt.column_text(1), "(def self)", line, character, cls_stmt.column_int(2) == cursor_file_id, depth, 1, memberFreq(self, mname2));
                                }
                            }
                        }

                        const mix_stmt = try self.cachedStmt(
                            \\SELECT DISTINCT s2.name, s2.doc, s2.file_id FROM symbols s2
                            \\JOIN mixins m ON s2.file_id IN (
                            \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name=m.module_name
                            \\)
                            \\WHERE m.class_id IN (
                            \\  SELECT id FROM symbols WHERE kind IN ('class','module') AND name=?
                            \\) AND s2.kind IN ('def','association','scope') AND m.kind IN ('include','extend')
                        );
                        defer mix_stmt.reset();
                        mix_stmt.bind_text(1, current);
                        while (try mix_stmt.step()) {
                            const mname2 = mix_stmt.column_text(0);
                            if (seen_names.contains(mname2)) continue;
                            try seen_names.put(try ma.dupe(u8, mname2), {});
                            if (!first_dot) try wd.writeByte(',');
                            first_dot = false;
                            try writeMethodMemberItem(wd, mname2, mix_stmt.column_text(1), "(def)", line, character, mix_stmt.column_int(2) == cursor_file_id, depth, 2, memberFreq(self, mname2));
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
                            if (std.mem.eql(u8, pname, "ApplicationRecord") or std.mem.eql(u8, pname, "ActiveRecord::Base") or
                                std.mem.endsWith(u8, pname, "::ApplicationRecord")) is_ar_model = true;
                            // Superclasses are written bare (`Base`) while class
                            // symbols/methods are stored fully qualified (`Xf::Base`),
                            // so canonicalize an unqualified ancestor to its stored
                            // name (shortest `%::Base` suffix) before the next step.
                            var next_cur = try ma.dupe(u8, pname);
                            if (std.mem.indexOf(u8, pname, "::") == null) {
                                if (qualifyClassName(self, ma, pname)) |cn| next_cur = cn;
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
                // ActiveSupport Object extensions: with AS loaded (any Rails app)
                // every object gets blank?/present?/presence/try/in?. They live on
                // Object via monkeypatch, so the symbol-table walk never surfaces
                // them — same rationale as the universal set above, but Rails-gated.
                // Completion-only, deduped against real members.
                if (self.has_rails.load(.monotonic)) {
                    const as_object = [_][]const u8{ "blank?", "present?", "presence", "try", "try!", "in?" };
                    for (as_object) |am| {
                        if (seen_names.contains(am)) continue;
                        if (!first_dot) try wd.writeByte(',');
                        first_dot = false;
                        try wd.writeAll("{\"label\":");
                        try writeEscapedJson(wd, am);
                        try wd.writeAll(",\"kind\":2}");
                    }
                }
                // Class-object methods: a constant/singleton receiver (`Foo.`,
                // `described_class.`) IS the class, so `Class#new`/`allocate` always
                // apply — independent of AR. The AR class-query set below is additive
                // for models; this covers plain classes (services/workers/POROs) whose
                // `.new` would otherwise never surface. Completion-only.
                if (is_constant_recv) {
                    const class_obj = [_][]const u8{ "new", "allocate" };
                    for (class_obj) |cm| {
                        if (seen_names.contains(cm)) continue;
                        if (!first_dot) try wd.writeByte(',');
                        first_dot = false;
                        try wd.writeAll("{\"label\":");
                        try writeEscapedJson(wd, cm);
                        try wd.writeAll(",\"kind\":2}");
                    }
                }
                // ActiveRecord base API: a model (`< ApplicationRecord`) responds to a
                // large runtime-generated method set that exists in no source/schema —
                // `reload`/`save`/`update`/`destroy`/`where`/… . Inject the curated set
                // for AR models so those (very common) receivers complete. Completion-only.
                if (is_ar_model) {
                    const ar_inst = [_][]const u8{
                        "save",              "save!",            "update",             "update!",
                        "destroy",           "destroy!",         "reload",             "delete",
                        "persisted?",        "new_record?",      "destroyed?",         "valid?",
                        "invalid?",          "errors",           "attributes",         "attribute_names",
                        "assign_attributes", "update_attribute", "update_column",      "update_columns",
                        "touch",             "becomes",          "increment!",         "decrement!",
                        "toggle!",           "read_attribute",   "write_attribute",    "has_attribute?",
                        "changed?",          "changes",          "previous_changes",   "saved_changes",
                        "id",                "to_param",         "cache_key",          "lock!",
                        "with_lock",         "transaction",      "restore_attributes", "association",
                    };
                    for (ar_inst) |m| {
                        if (seen_names.contains(m)) continue;
                        if (!first_dot) try wd.writeByte(',');
                        first_dot = false;
                        try wd.writeAll("{\"label\":");
                        try writeEscapedJson(wd, m);
                        try wd.writeAll(",\"kind\":2}");
                    }
                    if (is_constant_recv) {
                        const ar_cls = [_][]const u8{
                            "where",      "find",       "find_by",     "find_by!",          "all",                   "first",
                            "last",       "create",     "create!",     "new",               "build",                 "exists?",
                            "count",      "sum",        "average",     "minimum",           "maximum",               "pluck",
                            "order",      "limit",      "offset",      "group",             "having",                "joins",
                            "includes",   "preload",    "eager_load",  "references",        "distinct",              "select",
                            "none",       "unscoped",   "find_each",   "find_or_create_by", "find_or_initialize_by", "take",
                            "update_all", "delete_all", "destroy_all", "where_not",         "or",                    "merge",
                        };
                        for (ar_cls) |m| {
                            if (seen_names.contains(m)) continue;
                            if (!first_dot) try wd.writeByte(',');
                            first_dot = false;
                            try wd.writeAll("{\"label\":");
                            try writeEscapedJson(wd, m);
                            try wd.writeAll(",\"kind\":2}");
                        }
                    }
                }
                // Collection-of-AR-model receiver (a relation): `@orders`/`accounts`
                // (Array[Model]) otherwise offer only Enumerable. A relation also responds to
                // AR query methods and the element model's named scopes. Completion-only,
                // Rails-gated. Not for index access (`arr[0].` already unwrapped to the element).
                if (!index_element and self.has_rails.load(.monotonic)) {
                    if (modelCollectionElement(self, ma, class_name_raw)) |elem| {
                        const rel_methods = [_][]const u8{
                            "where",    "where_not",  "order",           "limit",            "offset",     "group",
                            "having",   "joins",      "includes",        "preload",          "eager_load", "references",
                            "distinct", "select",     "pluck",           "count",            "sum",        "average",
                            "minimum",  "maximum",    "exists?",         "any?",             "none?",      "many?",
                            "find",     "find_by",    "find_each",       "first",            "last",       "take",
                            "reload",   "to_a",       "ids",             "merge",            "or",         "unscope",
                            // Enumerable core — a relation is enumerable; these were absent and
                            // caused `xs.all?`/`.map`/`.each` completion misses on collections.
                            "all?",     "map",        "each",            "reject",           "detect",     "filter",
                            "flat_map", "filter_map", "each_with_index", "each_with_object", "reduce",     "inject",
                            "min_by",   "max_by",     "sort_by",         "group_by",         "partition",  "find_index",
                            "include?", "empty?",     "size",            "length",           "tally",      "each_slice",
                        };
                        for (rel_methods) |m| {
                            if (seen_names.contains(m)) continue;
                            if (!first_dot) try wd.writeByte(',');
                            first_dot = false;
                            try wd.writeAll("{\"label\":");
                            try writeEscapedJson(wd, m);
                            try wd.writeAll(",\"kind\":2}");
                        }
                        if (self.cachedStmt("SELECT DISTINCT name FROM symbols WHERE (parent_name=?1 OR parent_name LIKE '%::'||?1) AND kind='scope'")) |ss| {
                            defer ss.reset();
                            ss.bind_text(1, elem);
                            while (ss.step() catch false) {
                                const sn = ss.column_text(0);
                                if (sn.len == 0 or seen_names.contains(sn)) continue;
                                try seen_names.put(try ma.dupe(u8, sn), {});
                                if (!first_dot) try wd.writeByte(',');
                                first_dot = false;
                                try wd.writeAll("{\"label\":");
                                try writeEscapedJson(wd, sn);
                                try wd.writeAll(",\"kind\":2}");
                            }
                        } else |_| {}
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
    // A real `receiver.` with no inferable type (untyped local/param/chain). Rather
    // than return nothing, fall back to workspace method names ranked by frequency.
    return try tier0Fallback(self, msg, line, character, word);
}
