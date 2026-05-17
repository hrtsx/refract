const std = @import("std");
const db_mod = @import("../db.zig");

pub const SymbolKind = enum(u8) {
    def,
    classdef,
    class_,
    module,
    constant,
    association,
    scope,
    validation,
    callback,
    other,

    pub fn fromText(s: []const u8) SymbolKind {
        if (s.len == 0) return .other;
        // Order by relative frequency in real codebases.
        if (std.mem.eql(u8, s, "def")) return .def;
        if (std.mem.eql(u8, s, "class")) return .class_;
        if (std.mem.eql(u8, s, "module")) return .module;
        if (std.mem.eql(u8, s, "classdef")) return .classdef;
        if (std.mem.eql(u8, s, "constant")) return .constant;
        if (std.mem.eql(u8, s, "association")) return .association;
        if (std.mem.eql(u8, s, "scope")) return .scope;
        if (std.mem.eql(u8, s, "validation")) return .validation;
        if (std.mem.eql(u8, s, "callback")) return .callback;
        return .other;
    }

    /// Mirrors `WHERE s.kind IN (...)` filter on the qualified-suffix branch
    /// in src/lsp/navigation.zig:589 (queryAndEmitDefinitions).
    pub fn matchesQualifiedSuffix(self: SymbolKind) bool {
        return switch (self) {
            .class_, .module, .association, .scope, .validation, .callback => true,
            else => false,
        };
    }
};

pub const HotSymbol = struct {
    name: []const u8,
    file_id: u32,
    line: u32,
    col: u32,
    kind: SymbolKind,
    is_bundled: bool,
    return_type: ?[]const u8,
    parent_name: ?[]const u8,
    /// Pre-formatted parameter signature for completion items (mirrors the
    /// SQL `GROUP_CONCAT(...)` over `params`). Empty when symbol has no params.
    params_sig: ?[]const u8,
    doc: ?[]const u8,
};

pub const LookupQuery = struct {
    receiver_type: ?[]const u8 = null,
};

pub const FileCacheEntry = struct {
    file_id: u32,
    symbols: []HotSymbol,
    last_access_tick: u64,
};

pub const FILE_CACHE_CAPACITY: usize = 32;

pub const FileCache = struct {
    entries: [FILE_CACHE_CAPACITY]?FileCacheEntry = [_]?FileCacheEntry{null} ** FILE_CACHE_CAPACITY,
    tick: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn get(self: *FileCache, file_id: u32) ?[]HotSymbol {
        for (self.entries) |maybe_entry| {
            if (maybe_entry) |entry| {
                if (entry.file_id == file_id) {
                    return entry.symbols;
                }
            }
        }
        return null;
    }

    pub fn put(self: *FileCache, file_id: u32, symbols: []HotSymbol) void {
        const now_tick = self.tick.load(.monotonic) +% 1;
        self.tick.store(now_tick, .monotonic);

        var oldest_idx: usize = 0;
        var oldest_tick: u64 = std.math.maxInt(u64);

        for (self.entries, 0..) |maybe_entry, i| {
            if (maybe_entry == null) {
                self.entries[i] = FileCacheEntry{ .file_id = file_id, .symbols = symbols, .last_access_tick = now_tick };
                return;
            }
            if (maybe_entry) |entry| {
                if (entry.file_id == file_id) {
                    self.entries[i] = FileCacheEntry{ .file_id = file_id, .symbols = symbols, .last_access_tick = now_tick };
                    return;
                }
                if (entry.last_access_tick < oldest_tick) {
                    oldest_tick = entry.last_access_tick;
                    oldest_idx = i;
                }
            }
        }

        self.entries[oldest_idx] = FileCacheEntry{ .file_id = file_id, .symbols = symbols, .last_access_tick = now_tick };
    }

    pub fn invalidate(self: *FileCache, file_id: u32) void {
        for (self.entries, 0..) |maybe_entry, i| {
            if (maybe_entry) |entry| {
                if (entry.file_id == file_id) {
                    self.entries[i] = null;
                    return;
                }
            }
        }
    }
};

pub const HotIndex = struct {
    arena: std.heap.ArenaAllocator,
    /// Keyed by symbol's stored name. Equivalent to `WHERE s.name = ?`.
    name_map: std.StringHashMapUnmanaged([]HotSymbol),
    /// Keyed by the part after the last "::" in the stored name.
    /// Equivalent to `WHERE s.name LIKE '%::' || ?`.
    tail_map: std.StringHashMapUnmanaged([]HotSymbol),
    /// file_id → workspace path. Mirrors `JOIN files f ON s.file_id = f.id`.
    file_paths: std.AutoHashMapUnmanaged(u32, []const u8),
    classes_by_file: std.AutoHashMapUnmanaged(u32, []const []const u8),
    /// Keyed by parent_name (class/module name); values are def/classdef
    /// HotSymbols belonging to that parent. Powers receiver-style hover and
    /// definition without an SQL round-trip.
    methods_by_parent: std.StringHashMapUnmanaged([]HotSymbol),
    /// All symbols sorted ascending by name for prefix scans.
    /// Equivalent to `WHERE s.name LIKE ? ESCAPE '\'` with a leading-anchor pattern.
    sorted_by_name: []HotSymbol,
    /// Pre-rendered hover markdown body (JSON-escaped, between `"value":"` and
    /// the trailing `"`). Keyed by `HotSymbol.name`. Populated at warmup for
    /// the top-N most-referenced symbols whose name is unambiguous in
    /// `name_map` (single def/classdef entry). Lookup-only after build;
    /// freed with the arena.
    pre_rendered_by_name: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Pre-rendered LocationLink JSON fragment (LSP 3.14+) for goto-definition.
    /// Stored *without* enclosing braces; navigation handler wraps with
    /// `{...,"originSelectionRange":{...}}` per request.
    pre_def_link_by_name: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Pre-rendered legacy Location JSON object for goto-definition on clients
    /// that did not negotiate definition-link. Fully self-contained — emit
    /// verbatim.
    pre_def_loc_by_name: std.StringHashMapUnmanaged([]const u8) = .empty,
    symbol_count: u32,
    file_count: u32,
    file_cache: FileCache = .{},

    pub fn deinit(self: *HotIndex) void {
        const child = self.arena.child_allocator;
        self.name_map.deinit(child);
        self.tail_map.deinit(child);
        self.file_paths.deinit(child);
        self.classes_by_file.deinit(child);
        self.methods_by_parent.deinit(child);
        self.pre_rendered_by_name.deinit(child);
        self.pre_def_link_by_name.deinit(child);
        self.pre_def_loc_by_name.deinit(child);
        self.arena.deinit();
    }

    /// Returns the pre-rendered, JSON-escaped hover markdown body for `name`,
    /// or null when the symbol was not in the top-N cache or its name is
    /// ambiguous across multiple defs/classdefs.
    pub fn lookupPreRendered(self: *const HotIndex, name: []const u8) ?[]const u8 {
        return self.pre_rendered_by_name.get(name);
    }

    /// Insert a pre-rendered hover body. Caller must allocate `name` and
    /// `body` with `self.arena.allocator()` so they live for the HotIndex
    /// lifetime.
    pub fn putPreRendered(self: *HotIndex, name: []const u8, body: []const u8) !void {
        try self.pre_rendered_by_name.put(self.arena.child_allocator, name, body);
    }

    /// LocationLink fragment (no enclosing braces) for goto-definition.
    pub fn lookupPreDefLink(self: *const HotIndex, name: []const u8) ?[]const u8 {
        return self.pre_def_link_by_name.get(name);
    }

    /// Legacy Location object (fully self-contained, includes braces).
    pub fn lookupPreDefLoc(self: *const HotIndex, name: []const u8) ?[]const u8 {
        return self.pre_def_loc_by_name.get(name);
    }

    pub fn putPreDefLink(self: *HotIndex, name: []const u8, body: []const u8) !void {
        try self.pre_def_link_by_name.put(self.arena.child_allocator, name, body);
    }

    pub fn putPreDefLoc(self: *HotIndex, name: []const u8, body: []const u8) !void {
        try self.pre_def_loc_by_name.put(self.arena.child_allocator, name, body);
    }

    pub fn lookupName(self: *const HotIndex, name: []const u8) []const HotSymbol {
        return if (self.name_map.get(name)) |s| s else &.{};
    }

    pub fn lookupTail(self: *const HotIndex, tail: []const u8) []const HotSymbol {
        return if (self.tail_map.get(tail)) |s| s else &.{};
    }

    pub fn pathFor(self: *const HotIndex, file_id: u32) ?[]const u8 {
        return self.file_paths.get(file_id);
    }

    pub fn classesIn(self: *const HotIndex, file_id: u32) []const []const u8 {
        return if (self.classes_by_file.get(file_id)) |s| s else &.{};
    }

    pub fn getSymbolsForFile(self: *const HotIndex, file_id: u32) ?[]const HotSymbol {
        return self.file_cache.get(file_id);
    }

    pub fn cacheSymbolsForFile(self: *HotIndex, file_id: u32, symbols: []HotSymbol) void {
        self.file_cache.put(file_id, symbols);
    }

    pub fn invalidateFileCache(self: *HotIndex, file_id: u32) void {
        self.file_cache.invalidate(file_id);
    }

    /// Returns def/classdef HotSymbols whose `parent_name` matches `class_name`.
    /// Used by hover/definition for `receiver.method` lookups.
    pub fn lookupMethodsOnClass(self: *const HotIndex, class_name: []const u8) []const HotSymbol {
        return if (self.methods_by_parent.get(class_name)) |s| s else &.{};
    }

    /// Returns the best-ranked HotSymbol for a method on a class, or null if
    /// no such method is recorded. Ranks by receiver type match, bundled
    /// stdlib for known types, and doc presence.
    pub fn lookupMethodOnClass(self: *const HotIndex, class_name: []const u8, method_name: []const u8) ?HotSymbol {
        return self.lookupMethodOnClassWithQuery(class_name, method_name, LookupQuery{});
    }

    pub fn lookupMethodOnClassWithQuery(self: *const HotIndex, class_name: []const u8, method_name: []const u8, query: LookupQuery) ?HotSymbol {
        const candidates = self.lookupMethodsOnClass(class_name);

        // First pass: collect candidates matching name and kind filters
        var count: usize = 0;
        var first_match: ?HotSymbol = null;
        for (candidates) |s| {
            if (!std.mem.eql(u8, s.name, method_name)) continue;
            if (s.kind != .def and s.kind != .classdef) continue;
            if (count == 0) first_match = s;
            count += 1;
        }

        // No matches
        if (count == 0) return null;

        // Single match: return immediately without scoring
        if (count == 1) return first_match;

        // Multiple matches with no receiver type: prefer non-bundled with doc,
        // then any non-bundled, then bundled with doc, then first.
        if (query.receiver_type == null) {
            var first_nonbundled: ?HotSymbol = null;
            for (candidates) |s| {
                if (!std.mem.eql(u8, s.name, method_name)) continue;
                if (s.kind != .def and s.kind != .classdef) continue;
                if (!s.is_bundled) {
                    if (s.doc != null) return s;
                    if (first_nonbundled == null) first_nonbundled = s;
                }
            }
            if (first_nonbundled) |s| return s;
            // All are bundled — prefer one with doc, fall back to first.
            for (candidates) |s| {
                if (!std.mem.eql(u8, s.name, method_name)) continue;
                if (s.kind != .def and s.kind != .classdef) continue;
                if (s.doc != null) return s;
            }
            return first_match;
        }

        // Multiple matches with receiver type: use scoring
        var best: ?HotSymbol = null;
        var best_score: u32 = 0;
        for (candidates) |s| {
            if (!std.mem.eql(u8, s.name, method_name)) continue;
            if (s.kind != .def and s.kind != .classdef) continue;
            const s_score = score(s, query);
            if (best == null or s_score > best_score or
                (s_score == best_score and scoreOrder(query, s, best.?)))
            {
                best = s;
                best_score = s_score;
            }
        }
        return best;
    }

    /// Append every symbol whose `name` contains `needle` (excluding leading-anchor
    /// matches already covered by `lookupPrefix`) into `out`. Linear scan; cheap
    /// on real corpora because comparisons short-circuit on the first byte.
    pub fn appendSubstringMatches(self: *const HotIndex, needle: []const u8, out: *std.ArrayList(HotSymbol), alloc: std.mem.Allocator) !void {
        if (needle.len == 0) return;
        for (self.sorted_by_name) |sym| {
            if (sym.name.len <= needle.len) continue;
            if (std.mem.startsWith(u8, sym.name, needle)) continue;
            if (std.mem.indexOf(u8, sym.name, needle) != null) {
                try out.append(alloc, sym);
            }
        }
    }

    /// Returns all symbols whose `name` begins with `prefix`. Empty prefix
    /// yields nothing (callers should not run unbounded completion).
    pub fn lookupPrefix(self: *const HotIndex, prefix: []const u8) []const HotSymbol {
        if (prefix.len == 0) return &.{};
        const items = self.sorted_by_name;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.lessThan(u8, items[mid].name, prefix)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        var end: usize = lo;
        while (end < items.len and std.mem.startsWith(u8, items[end].name, prefix)) {
            end += 1;
        }
        return items[lo..end];
    }
};

const BUNDLED_PREFIX = "<bundled>/";

const BUILTIN_TYPES = [_][]const u8{
    "String", "Array", "Hash", "Integer", "Float", "Symbol", "Regexp", "Range", "NilClass",
};

fn isBuiltinType(name: ?[]const u8) bool {
    if (name == null) return false;
    for (BUILTIN_TYPES) |builtin| {
        if (std.mem.eql(u8, name.?, builtin)) return true;
    }
    return false;
}

fn score(candidate: HotSymbol, query: LookupQuery) u32 {
    var s: u32 = 0;
    if (query.receiver_type != null and candidate.parent_name != null and
        std.mem.eql(u8, candidate.parent_name.?, query.receiver_type.?))
    {
        s += 200;
    }
    if (candidate.is_bundled and isBuiltinType(query.receiver_type)) {
        s += 100;
    }
    if (candidate.doc != null and candidate.doc.?.len > 0) {
        s += 50;
    }
    return s;
}

fn scoreOrder(context: LookupQuery, a: HotSymbol, b: HotSymbol) bool {
    const score_a = score(a, context);
    const score_b = score(b, context);
    if (score_a != score_b) return score_a > score_b;
    const cmp_parent = std.mem.order(u8, a.parent_name orelse "", b.parent_name orelse "");
    if (cmp_parent != .eq) return cmp_parent == .lt;
    const cmp_name = std.mem.order(u8, a.name, b.name);
    if (cmp_name != .eq) return cmp_name == .lt;
    return a.line < b.line;
}

/// Build a fresh HotIndex by streaming the symbols + files tables once.
/// Caller owns the returned pointer; deinit() releases everything.
pub fn buildFromDb(parent: std.mem.Allocator, db: db_mod.Db) !*HotIndex {
    const idx = try parent.create(HotIndex);
    errdefer parent.destroy(idx);

    idx.* = HotIndex{
        .arena = std.heap.ArenaAllocator.init(parent),
        .name_map = .empty,
        .tail_map = .empty,
        .file_paths = .empty,
        .classes_by_file = .empty,
        .methods_by_parent = .empty,
        .sorted_by_name = &.{},
        .symbol_count = 0,
        .file_count = 0,
    };
    errdefer idx.arena.deinit();

    const arena_alloc = idx.arena.allocator();

    {
        const fstmt = try db.prepare("SELECT id, path FROM files");
        defer fstmt.finalize();
        while (try fstmt.step()) {
            const fid: u32 = @intCast(@max(0, fstmt.column_int(0)));
            const owned = try arena_alloc.dupe(u8, fstmt.column_text(1));
            try idx.file_paths.put(parent, fid, owned);
            idx.file_count += 1;
        }
    }

    var name_lists: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(HotSymbol)) = .empty;
    var tail_lists: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(HotSymbol)) = .empty;
    var classes_lists: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]const u8)) = .empty;
    var methods_lists: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(HotSymbol)) = .empty;
    defer {
        var ni = name_lists.iterator();
        while (ni.next()) |e| e.value_ptr.deinit(parent);
        name_lists.deinit(parent);
        var ti = tail_lists.iterator();
        while (ti.next()) |e| e.value_ptr.deinit(parent);
        tail_lists.deinit(parent);
        var ci = classes_lists.iterator();
        while (ci.next()) |e| e.value_ptr.deinit(parent);
        classes_lists.deinit(parent);
        var mi = methods_lists.iterator();
        while (mi.next()) |e| e.value_ptr.deinit(parent);
        methods_lists.deinit(parent);
    }

    {
        const profiling = std.c.getenv("REFRACT_INIT_PROFILE") != null;
        const query_start = if (profiling) std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() else 0;
        const sstmt = try db.prepare(
            \\SELECT s.name, s.kind, s.line, s.col, s.file_id, s.return_type, s.parent_name,
            \\  s.doc,
            \\  (SELECT GROUP_CONCAT(
            \\    CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
            \\    WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
            \\    ELSE p.name END, ', ')
            \\   FROM params p WHERE p.symbol_id=s.id ORDER BY p.position)
            \\FROM symbols s
        );
        defer sstmt.finalize();

        var row_count: u32 = 0;
        while (try sstmt.step()) {
            row_count += 1;
            const name_text = sstmt.column_text(0);
            if (name_text.len == 0) continue;
            const kind_text = sstmt.column_text(1);
            const line: u32 = @intCast(@max(0, sstmt.column_int(2)));
            const col: u32 = @intCast(@max(0, sstmt.column_int(3)));
            const file_id: u32 = @intCast(@max(0, sstmt.column_int(4)));
            const ret_text = sstmt.column_text(5);
            const par_text = sstmt.column_text(6);
            const doc_text = sstmt.column_text(7);
            const sig_text = sstmt.column_text(8);

            const owned_name = try arena_alloc.dupe(u8, name_text);
            const owned_return: ?[]const u8 = if (ret_text.len == 0) null else try arena_alloc.dupe(u8, ret_text);
            const owned_parent: ?[]const u8 = if (par_text.len == 0) null else try arena_alloc.dupe(u8, par_text);
            const owned_doc: ?[]const u8 = if (doc_text.len == 0) null else try arena_alloc.dupe(u8, doc_text);
            const owned_sig: ?[]const u8 = if (sig_text.len == 0) null else try arena_alloc.dupe(u8, sig_text);
            const path_opt = idx.file_paths.get(file_id);
            const kind = SymbolKind.fromText(kind_text);
            const sym = HotSymbol{
                .name = owned_name,
                .file_id = file_id,
                .line = line,
                .col = col,
                .kind = kind,
                .is_bundled = if (path_opt) |p| std.mem.startsWith(u8, p, BUNDLED_PREFIX) else false,
                .return_type = owned_return,
                .parent_name = owned_parent,
                .params_sig = owned_sig,
                .doc = owned_doc,
            };

            const ngop = try name_lists.getOrPut(parent, owned_name);
            if (!ngop.found_existing) ngop.value_ptr.* = .empty;
            try ngop.value_ptr.append(parent, sym);

            if (std.mem.lastIndexOf(u8, owned_name, "::")) |sep| {
                const tail = owned_name[sep + 2 ..];
                if (tail.len > 0) {
                    const tgop = try tail_lists.getOrPut(parent, tail);
                    if (!tgop.found_existing) tgop.value_ptr.* = .empty;
                    try tgop.value_ptr.append(parent, sym);
                }
            }

            if (kind == .class_ or kind == .module) {
                const cgop = try classes_lists.getOrPut(parent, file_id);
                if (!cgop.found_existing) cgop.value_ptr.* = .empty;
                var seen = false;
                for (cgop.value_ptr.items) |existing| {
                    if (std.mem.eql(u8, existing, owned_name)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try cgop.value_ptr.append(parent, owned_name);
            }

            if ((kind == .def or kind == .classdef) and owned_parent != null) {
                const mgop = try methods_lists.getOrPut(parent, owned_parent.?);
                if (!mgop.found_existing) mgop.value_ptr.* = .empty;
                try mgop.value_ptr.append(parent, sym);
            }

            idx.symbol_count += 1;
        }
        if (profiling) {
            const query_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - query_start;
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "refract_profile: hot_index_query={d}ms rows={d}\n", .{ query_ms, row_count }) catch "refract_profile: hot_index_query\n";
            std.debug.print("{s}", .{msg});
        }
    }

    // User-code symbols win on collision: emit before bundled stdlib RBS so
    // goto-def on a same-named method resolves to the workspace definition.
    // Mirrors the precedence the SQL path got from rowid iteration order.
    var ni = name_lists.iterator();
    while (ni.next()) |entry| {
        std.mem.sort(HotSymbol, entry.value_ptr.items, {}, lessByBundled);
        const slice = try arena_alloc.dupe(HotSymbol, entry.value_ptr.items);
        try idx.name_map.put(parent, entry.key_ptr.*, slice);
    }
    var ti = tail_lists.iterator();
    while (ti.next()) |entry| {
        std.mem.sort(HotSymbol, entry.value_ptr.items, {}, lessByBundled);
        const slice = try arena_alloc.dupe(HotSymbol, entry.value_ptr.items);
        try idx.tail_map.put(parent, entry.key_ptr.*, slice);
    }

    var ci = classes_lists.iterator();
    while (ci.next()) |entry| {
        const slice = try arena_alloc.dupe([]const u8, entry.value_ptr.items);
        try idx.classes_by_file.put(parent, entry.key_ptr.*, slice);
    }

    var mi = methods_lists.iterator();
    while (mi.next()) |entry| {
        std.mem.sort(HotSymbol, entry.value_ptr.items, {}, lessByBundled);
        const slice = try arena_alloc.dupe(HotSymbol, entry.value_ptr.items);
        try idx.methods_by_parent.put(parent, entry.key_ptr.*, slice);
    }

    var sorted = try arena_alloc.alloc(HotSymbol, idx.symbol_count);
    var sorted_i: usize = 0;
    var nm_it = idx.name_map.iterator();
    while (nm_it.next()) |entry| {
        for (entry.value_ptr.*) |sym| {
            sorted[sorted_i] = sym;
            sorted_i += 1;
        }
    }
    std.mem.sort(HotSymbol, sorted[0..sorted_i], {}, lessByName);
    idx.sorted_by_name = sorted[0..sorted_i];

    return idx;
}

fn lessByName(_: void, a: HotSymbol, b: HotSymbol) bool {
    const c = std.mem.order(u8, a.name, b.name);
    if (c != .eq) return c == .lt;
    if (a.is_bundled != b.is_bundled) return !a.is_bundled;
    return a.file_id < b.file_id;
}

fn lessByBundled(_: void, a: HotSymbol, b: HotSymbol) bool {
    if (a.is_bundled != b.is_bundled) return !a.is_bundled;
    return a.file_id < b.file_id;
}

test "build empty hot index" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    const idx = try buildFromDb(std.testing.allocator, db);
    defer {
        idx.deinit();
        std.testing.allocator.destroy(idx);
    }
    try std.testing.expectEqual(@as(u32, 0), idx.symbol_count);
}

test "user code wins precedence over bundled stdlib on name collision" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO files(path,mtime) VALUES('<bundled>/core/string.rbs',1)");
    const bundled_fid = db.last_insert_rowid();
    try db.exec("INSERT INTO files(path,mtime) VALUES('/repo/user.rb',1)");
    const user_fid = db.last_insert_rowid();

    const ins = try db.prepare("INSERT INTO symbols(file_id,name,kind,line,col) VALUES(?,?,?,?,?)");
    defer ins.finalize();
    ins.bind_int(1, bundled_fid);
    ins.bind_text(2, "upcase");
    ins.bind_text(3, "def");
    ins.bind_int(4, 100);
    ins.bind_int(5, 0);
    _ = try ins.step();
    ins.reset();
    ins.bind_int(1, user_fid);
    ins.bind_text(2, "upcase");
    ins.bind_text(3, "def");
    ins.bind_int(4, 5);
    ins.bind_int(5, 4);
    _ = try ins.step();

    const idx = try buildFromDb(std.testing.allocator, db);
    defer {
        idx.deinit();
        std.testing.allocator.destroy(idx);
    }

    const matches = idx.lookupName("upcase");
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(false, matches[0].is_bundled);
    try std.testing.expectEqual(true, matches[1].is_bundled);
}

test "lookupPrefix returns matching symbols sorted by name" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path,mtime) VALUES('a.rb',1)");
    const fid = db.last_insert_rowid();
    const ins = try db.prepare("INSERT INTO symbols(file_id,name,kind,line,col) VALUES(?,?,?,?,?)");
    defer ins.finalize();
    const names = [_][]const u8{ "Account", "AccountBalance", "User", "AccountManager", "Foo" };
    for (names) |nm| {
        ins.bind_int(1, fid);
        ins.bind_text(2, nm);
        ins.bind_text(3, "class");
        ins.bind_int(4, 1);
        ins.bind_int(5, 0);
        _ = try ins.step();
        ins.reset();
    }
    const idx = try buildFromDb(std.testing.allocator, db);
    defer {
        idx.deinit();
        std.testing.allocator.destroy(idx);
    }
    const matches = idx.lookupPrefix("Account");
    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("Account", matches[0].name);
    try std.testing.expectEqualStrings("AccountBalance", matches[1].name);
    try std.testing.expectEqualStrings("AccountManager", matches[2].name);
    try std.testing.expectEqual(@as(usize, 0), idx.lookupPrefix("").len);
    try std.testing.expectEqual(@as(usize, 0), idx.lookupPrefix("Z").len);
}

test "lookupMethodOnClass returns def for matching parent and method" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path,mtime) VALUES('/repo/account.rb',1)");
    const fid = db.last_insert_rowid();
    const ins = try db.prepare("INSERT INTO symbols(file_id,name,kind,line,col,parent_name) VALUES(?,?,?,?,?,?)");
    defer ins.finalize();
    ins.bind_int(1, fid);
    ins.bind_text(2, "deposit");
    ins.bind_text(3, "def");
    ins.bind_int(4, 12);
    ins.bind_int(5, 2);
    ins.bind_text(6, "Account");
    _ = try ins.step();

    const idx = try buildFromDb(std.testing.allocator, db);
    defer {
        idx.deinit();
        std.testing.allocator.destroy(idx);
    }

    const hit = idx.lookupMethodOnClass("Account", "deposit").?;
    try std.testing.expectEqualStrings("deposit", hit.name);
    try std.testing.expectEqual(@as(u32, 12), hit.line);
    try std.testing.expectEqual(SymbolKind.def, hit.kind);
    try std.testing.expectEqualStrings("Account", hit.parent_name.?);

    try std.testing.expect(idx.lookupMethodOnClass("Account", "withdraw") == null);
    try std.testing.expect(idx.lookupMethodOnClass("Other", "deposit") == null);
}

test "lookupMethodOnClass prefers candidate with doc" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path,mtime) VALUES('/repo/a.rb',1)");
    const fid_a = db.last_insert_rowid();
    try db.exec("INSERT INTO files(path,mtime) VALUES('/repo/b.rb',1)");
    const fid_b = db.last_insert_rowid();

    const ins = try db.prepare("INSERT INTO symbols(file_id,name,kind,line,col,parent_name,doc) VALUES(?,?,?,?,?,?,?)");
    defer ins.finalize();
    // Undocumented variant first
    ins.bind_int(1, fid_a);
    ins.bind_text(2, "save");
    ins.bind_text(3, "def");
    ins.bind_int(4, 5);
    ins.bind_int(5, 0);
    ins.bind_text(6, "Record");
    ins.bind_null(7);
    _ = try ins.step();
    ins.reset();
    // Documented variant second
    ins.bind_int(1, fid_b);
    ins.bind_text(2, "save");
    ins.bind_text(3, "def");
    ins.bind_int(4, 9);
    ins.bind_int(5, 0);
    ins.bind_text(6, "Record");
    ins.bind_text(7, "Persists the record.");
    _ = try ins.step();

    const idx = try buildFromDb(std.testing.allocator, db);
    defer {
        idx.deinit();
        std.testing.allocator.destroy(idx);
    }

    const hit = idx.lookupMethodOnClass("Record", "save").?;
    try std.testing.expect(hit.doc != null);
    try std.testing.expectEqualStrings("Persists the record.", hit.doc.?);
}

test "lookupMethodOnClass accepts classdef and rejects non-method kinds" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path,mtime) VALUES('/repo/u.rb',1)");
    const fid = db.last_insert_rowid();

    const ins = try db.prepare("INSERT INTO symbols(file_id,name,kind,line,col,parent_name) VALUES(?,?,?,?,?,?)");
    defer ins.finalize();
    // classdef should match
    ins.bind_int(1, fid);
    ins.bind_text(2, "find");
    ins.bind_text(3, "classdef");
    ins.bind_int(4, 3);
    ins.bind_int(5, 0);
    ins.bind_text(6, "User");
    _ = try ins.step();
    ins.reset();
    // scope must NOT be returned by lookupMethodOnClass
    ins.bind_int(1, fid);
    ins.bind_text(2, "active");
    ins.bind_text(3, "scope");
    ins.bind_int(4, 7);
    ins.bind_int(5, 0);
    ins.bind_text(6, "User");
    _ = try ins.step();

    const idx = try buildFromDb(std.testing.allocator, db);
    defer {
        idx.deinit();
        std.testing.allocator.destroy(idx);
    }

    const hit = idx.lookupMethodOnClass("User", "find").?;
    try std.testing.expectEqual(SymbolKind.classdef, hit.kind);
    try std.testing.expect(idx.lookupMethodOnClass("User", "active") == null);
}

test "build with one symbol" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path,mtime) VALUES('foo.rb',1)");
    const fid = db.last_insert_rowid();
    const ins = try db.prepare("INSERT INTO symbols(file_id,name,kind,line,col) VALUES(?,?,?,?,?)");
    defer ins.finalize();
    ins.bind_int(1, fid);
    ins.bind_text(2, "Calculator::add");
    ins.bind_text(3, "def");
    ins.bind_int(4, 7);
    ins.bind_int(5, 4);
    _ = try ins.step();

    const idx = try buildFromDb(std.testing.allocator, db);
    defer {
        idx.deinit();
        std.testing.allocator.destroy(idx);
    }
    try std.testing.expectEqual(@as(u32, 1), idx.symbol_count);
    const direct = idx.lookupName("Calculator::add");
    try std.testing.expectEqual(@as(usize, 1), direct.len);
    try std.testing.expectEqual(@as(u32, 7), direct[0].line);
    const tail = idx.lookupTail("add");
    try std.testing.expectEqual(@as(usize, 1), tail.len);
    try std.testing.expectEqualStrings("foo.rb", idx.pathFor(@intCast(fid)).?);
}

test "score ranking breaks ties: matching receiver_type wins" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();
    try db.exec("INSERT INTO files(path,mtime) VALUES('/repo/user.rb',1)");
    const user_fid = db.last_insert_rowid();
    try db.exec("INSERT INTO files(path,mtime) VALUES('<bundled>/string.rbs',1)");
    const bundled_fid = db.last_insert_rowid();

    const ins = try db.prepare("INSERT INTO symbols(file_id,name,kind,line,col,parent_name) VALUES(?,?,?,?,?,?)");
    defer ins.finalize();
    ins.bind_int(1, user_fid);
    ins.bind_text(2, "upcase");
    ins.bind_text(3, "def");
    ins.bind_int(4, 5);
    ins.bind_int(5, 0);
    ins.bind_text(6, "MyString");
    _ = try ins.step();
    ins.reset();
    ins.bind_int(1, bundled_fid);
    ins.bind_text(2, "upcase");
    ins.bind_text(3, "def");
    ins.bind_int(4, 100);
    ins.bind_int(5, 0);
    ins.bind_text(6, "String");
    _ = try ins.step();

    const idx = try buildFromDb(std.testing.allocator, db);
    defer {
        idx.deinit();
        std.testing.allocator.destroy(idx);
    }

    const query = LookupQuery{ .receiver_type = "String" };
    const hit = idx.lookupMethodOnClassWithQuery("String", "upcase", query).?;
    try std.testing.expectEqualStrings("String", hit.parent_name.?);
    try std.testing.expectEqual(true, hit.is_bundled);
}

test "lookupMethodOnClassWithQuery skips scoring for null receiver_type and single match" {
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO files(path,mtime) VALUES('/repo/lib.rb',1)");
    const fid = db.last_insert_rowid();

    const ins = try db.prepare("INSERT INTO symbols(file_id,name,kind,line,col,parent_name) VALUES(?,?,?,?,?,?)");
    defer ins.finalize();

    // Build 1000 candidates with same name "foo" but different parent_name values
    for (0..1000) |i| {
        var parent_buf: [32]u8 = undefined;
        const parent_str = std.fmt.bufPrint(&parent_buf, "Parent{d}", .{i}) catch "ParentX";

        ins.bind_int(1, fid);
        ins.bind_text(2, "foo");
        ins.bind_text(3, "def");
        ins.bind_int(4, @intCast(i));
        ins.bind_int(5, 0);
        ins.bind_text(6, parent_str);
        _ = try ins.step();
        ins.reset();
    }

    const idx = try buildFromDb(std.testing.allocator, db);
    defer {
        idx.deinit();
        std.testing.allocator.destroy(idx);
    }

    // Test 1: null receiver_type returns first non-bundled (precedence without scoring)
    const hit_null = idx.lookupMethodOnClassWithQuery("Parent500", "foo", LookupQuery{}).?;
    try std.testing.expectEqualStrings("foo", hit_null.name);
    try std.testing.expectEqualStrings("Parent500", hit_null.parent_name.?);

    // Test 2: with receiver_type, scoring path finds the matching parent
    const query_with_type = LookupQuery{ .receiver_type = "Parent500" };
    const hit_typed = idx.lookupMethodOnClassWithQuery("Parent500", "foo", query_with_type).?;
    try std.testing.expectEqualStrings("foo", hit_typed.name);
    try std.testing.expectEqualStrings("Parent500", hit_typed.parent_name.?);

    // Both should return the same result (the single candidate for Parent500)
    try std.testing.expectEqual(hit_null.line, hit_typed.line);
}
