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
    symbol_count: u32,
    file_count: u32,

    pub fn deinit(self: *HotIndex) void {
        const child = self.arena.child_allocator;
        self.name_map.deinit(child);
        self.tail_map.deinit(child);
        self.file_paths.deinit(child);
        self.classes_by_file.deinit(child);
        self.arena.deinit();
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
};

const BUNDLED_PREFIX = "<bundled>/";

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
    }

    {
        const sstmt = try db.prepare(
            \\SELECT s.name, s.kind, s.line, s.col, s.file_id, s.return_type, s.parent_name
            \\FROM symbols s
        );
        defer sstmt.finalize();

        while (try sstmt.step()) {
            const name_text = sstmt.column_text(0);
            if (name_text.len == 0) continue;
            const kind_text = sstmt.column_text(1);
            const line: u32 = @intCast(@max(0, sstmt.column_int(2)));
            const col: u32 = @intCast(@max(0, sstmt.column_int(3)));
            const file_id: u32 = @intCast(@max(0, sstmt.column_int(4)));
            const ret_text = sstmt.column_text(5);
            const par_text = sstmt.column_text(6);

            const owned_name = try arena_alloc.dupe(u8, name_text);
            const owned_return: ?[]const u8 = if (ret_text.len == 0) null else try arena_alloc.dupe(u8, ret_text);
            const owned_parent: ?[]const u8 = if (par_text.len == 0) null else try arena_alloc.dupe(u8, par_text);
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

            idx.symbol_count += 1;
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

    return idx;
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
