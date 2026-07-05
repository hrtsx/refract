const std = @import("std");
const db_mod = @import("../db.zig");
const type_oracle_hot = @import("type_oracle_hot.zig");

pub const Source = enum {
    sorbet,
    steep,
    type_oracle,
    rbs_param,
    literal,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .sorbet => "sorbet",
            .steep => "steep",
            .type_oracle => "type_oracle",
            .rbs_param => "rbs",
            .literal => "literal",
        };
    }
};

pub const TypeResult = struct {
    type_str: []const u8, // owned by alloc
    source: Source,
    confidence: u8, // 0..100

    pub fn deinit(self: *TypeResult, alloc: std.mem.Allocator) void {
        alloc.free(self.type_str);
    }
};

pub const DEFAULT_SURFACE_THRESHOLD: u8 = 80;

/// Resolution chain: sorbet (≥0.8) → steep (≥0.8) → type_oracle (any) → rbs param → literal.
/// Returns first hit. Caller owns result.type_str.
pub fn resolve(
    alloc: std.mem.Allocator,
    db: db_mod.Db,
    fqn: []const u8,
    method_name: ?[]const u8,
    param_pos: i32,
) ?TypeResult {
    if (selectSorbet(alloc, db, fqn, method_name) catch null) |r| return r;
    if (selectSteep(alloc, db, fqn, method_name) catch null) |r| return r;
    if (method_name) |mn| {
        if (param_pos == -1) {
            if (type_oracle_hot.lookup(fqn, mn)) |t| {
                const owned = alloc.dupe(u8, t) catch null;
                if (owned) |o| return TypeResult{ .type_str = o, .source = .type_oracle, .confidence = 90 };
            }
        }
    }
    if (selectOracle(alloc, db, fqn, method_name, param_pos) catch null) |r| return r;
    if (method_name) |mn| {
        if (selectParam(alloc, db, fqn, mn, param_pos) catch null) |r| return r;
    }
    if (selectLiteral(alloc, db, fqn) catch null) |r| return r;
    return null;
}

// Confidence is a 0..100 domain, but a corrupted DB value could sit outside it
// and trap a bare u8 @intCast in ReleaseSafe. Clamp instead of trusting the row.
fn clampConfidence(v: anytype) u8 {
    if (v <= 0) return 0;
    if (v >= 100) return 100;
    return @intCast(v);
}

fn selectSorbet(alloc: std.mem.Allocator, db: db_mod.Db, fqn: []const u8, method_name: ?[]const u8) !?TypeResult {
    const sql = if (method_name == null)
        "SELECT type_str, confidence FROM sorbet_results WHERE fqn=? AND confidence >= 80 ORDER BY ts_us DESC LIMIT 1"
    else
        "SELECT type_str, confidence FROM sorbet_results WHERE fqn=? AND kind='method' AND confidence >= 80 ORDER BY ts_us DESC LIMIT 1";
    const stmt = try db.prepare(sql);
    defer stmt.finalize();
    if (method_name == null) {
        stmt.bind_text(1, fqn);
    } else {
        const composed = try std.fmt.allocPrint(alloc, "{s}#{s}", .{ fqn, method_name.? });
        defer alloc.free(composed);
        stmt.bind_text(1, composed);
    }
    if (!(try stmt.step())) return null;
    const t = try alloc.dupe(u8, stmt.column_text(0));
    return TypeResult{ .type_str = t, .source = .sorbet, .confidence = clampConfidence(stmt.column_int(1)) };
}

fn selectSteep(alloc: std.mem.Allocator, db: db_mod.Db, fqn: []const u8, method_name: ?[]const u8) !?TypeResult {
    const sql = if (method_name == null)
        "SELECT type_str, confidence FROM steep_results WHERE fqn=? AND confidence >= 80 ORDER BY ts_us DESC LIMIT 1"
    else
        "SELECT type_str, confidence FROM steep_results WHERE fqn=? AND kind='method' AND confidence >= 80 ORDER BY ts_us DESC LIMIT 1";
    const stmt = try db.prepare(sql);
    defer stmt.finalize();
    if (method_name == null) {
        stmt.bind_text(1, fqn);
    } else {
        const composed = try std.fmt.allocPrint(alloc, "{s}#{s}", .{ fqn, method_name.? });
        defer alloc.free(composed);
        stmt.bind_text(1, composed);
    }
    if (!(try stmt.step())) return null;
    const t = try alloc.dupe(u8, stmt.column_text(0));
    return TypeResult{ .type_str = t, .source = .steep, .confidence = clampConfidence(stmt.column_int(1)) };
}

fn selectOracle(alloc: std.mem.Allocator, db: db_mod.Db, fqn: []const u8, method_name: ?[]const u8, param_pos: i32) !?TypeResult {
    const stmt = try db.prepare(
        "SELECT type_str, confidence FROM type_oracle WHERE fqn=? AND " ++
            "(method_name IS ?  OR method_name = ?) AND param_pos = ? ORDER BY confidence DESC LIMIT 1",
    );
    defer stmt.finalize();
    stmt.bind_text(1, fqn);
    if (method_name) |mn| {
        stmt.bind_text(2, mn);
        stmt.bind_text(3, mn);
    } else {
        stmt.bind_null(2);
        stmt.bind_null(3);
    }
    stmt.bind_int(4, param_pos);
    if (!(try stmt.step())) return null;
    const t = try alloc.dupe(u8, stmt.column_text(0));
    return TypeResult{ .type_str = t, .source = .type_oracle, .confidence = clampConfidence(stmt.column_int(1)) };
}

fn selectParam(alloc: std.mem.Allocator, db: db_mod.Db, fqn: []const u8, method_name: []const u8, param_pos: i32) !?TypeResult {
    if (param_pos < 0) return null;
    const stmt = try db.prepare(
        "SELECT p.type_hint, p.confidence FROM params p " ++
            "JOIN symbols s ON s.id = p.symbol_id " ++
            "WHERE s.parent_name = ? AND s.name = ? AND p.position = ? AND p.type_hint IS NOT NULL " ++
            "ORDER BY p.confidence DESC LIMIT 1",
    );
    defer stmt.finalize();
    stmt.bind_text(1, fqn);
    stmt.bind_text(2, method_name);
    stmt.bind_int(3, param_pos);
    if (!(try stmt.step())) return null;
    const t = try alloc.dupe(u8, stmt.column_text(0));
    return TypeResult{ .type_str = t, .source = .rbs_param, .confidence = clampConfidence(stmt.column_int(1)) };
}

fn selectLiteral(alloc: std.mem.Allocator, db: db_mod.Db, fqn: []const u8) !?TypeResult {
    const stmt = try db.prepare(
        "SELECT return_type FROM symbols WHERE parent_name IS NULL AND name = ? AND return_type IS NOT NULL LIMIT 1",
    );
    defer stmt.finalize();
    stmt.bind_text(1, fqn);
    if (!(try stmt.step())) return null;
    const t = try alloc.dupe(u8, stmt.column_text(0));
    return TypeResult{ .type_str = t, .source = .literal, .confidence = 30 };
}

/// Reduce a Sorbet/Steep `type_str` to a bare class name suitable for
/// looking up in the symbols table. Strips `Class<X>` wrappers, `T.nilable(X)`,
/// `T::Array[X]` / `T::Hash[K, V]` / `T::Set[X]` shapes, and generic parameters.
/// Iterates to fixpoint with a depth cap of 4 to defang adversarial inputs.
/// Returns owned bytes the caller frees.
pub fn stripWrapper(alloc: std.mem.Allocator, type_str: []const u8) ![]u8 {
    var current = std.mem.trim(u8, type_str, " \t");
    var depth: u8 = 0;
    while (depth < 4) : (depth += 1) {
        const next = stripOneLevel(current) orelse break;
        if (next.ptr == current.ptr and next.len == current.len) break;
        current = std.mem.trim(u8, next, " \t");
    }
    return try alloc.dupe(u8, current);
}

fn stripOneLevel(t: []const u8) ?[]const u8 {
    if (t.len == 0) return null;
    if (std.mem.startsWith(u8, t, "Class<") and std.mem.endsWith(u8, t, ">")) {
        return t["Class<".len .. t.len - 1];
    }
    if (std.mem.startsWith(u8, t, "T.nilable(") and std.mem.endsWith(u8, t, ")")) {
        return t["T.nilable(".len .. t.len - 1];
    }
    if (std.mem.startsWith(u8, t, "T.must(") and std.mem.endsWith(u8, t, ")")) {
        return t["T.must(".len .. t.len - 1];
    }
    // PR6: T.let(value, Type) / T.cast(value, Type) — Sorbet uses these to
    // narrow a local var's type. The whole expression's type is the second
    // argument; strip down to it. T.unsafe(x) opts out → unresolvable, drop.
    if (extractSorbetCastSecond(t, "T.let(")) |inner| return inner;
    if (extractSorbetCastSecond(t, "T.cast(")) |inner| return inner;
    if (extractSorbetCastSecond(t, "T.assert_type!(")) |inner| return inner;
    if (std.mem.startsWith(u8, t, "T.unsafe(") and std.mem.endsWith(u8, t, ")")) {
        return t["T.unsafe(".len .. t.len - 1];
    }
    if (std.mem.startsWith(u8, t, "T::")) {
        const after_t = t[3..];
        const lb = std.mem.indexOfAny(u8, after_t, "<[") orelse return after_t;
        if (lb == 0) return null;
        return after_t[0..lb];
    }
    const lbracket = std.mem.indexOfAny(u8, t, "<[");
    if (lbracket) |idx| if (idx > 0) {
        return t[0..idx];
    };
    return null;
}

/// `T.let(value, Type)` shape — grab `Type` from after the top-level comma.
/// Respects nested parens so `T.let(x.foo(1), Hash[K,V])` still cuts at the
/// outer separator.
fn extractSorbetCastSecond(t: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, t, prefix)) return null;
    if (!std.mem.endsWith(u8, t, ")")) return null;
    const body = t[prefix.len .. t.len - 1];
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        switch (c) {
            '(', '[', '{', '<' => depth += 1,
            ')', ']', '}', '>' => depth -= 1,
            ',' => if (depth == 0) {
                var rest = body[i + 1 ..];
                rest = std.mem.trim(u8, rest, " \t");
                if (rest.len == 0) return null;
                return rest;
            },
            else => {},
        }
    }
    return null;
}

/// External type-checker oracle only: Sorbet (≥0.8) → Steep (≥0.8). Cheaper
/// than `resolve` — two indexed lookups, no oracle/rbs/literal fallback — and
/// scoped to authoritative sources, for the completion hot path. Returns null
/// (no result, no cost beyond two indexed misses) when neither checker has a
/// type for `fqn`, e.g. every plain-Ruby workspace. Caller owns type_str.
pub fn resolveExternalOracle(alloc: std.mem.Allocator, db: db_mod.Db, fqn: []const u8) ?TypeResult {
    if (selectSorbet(alloc, db, fqn, null) catch null) |r| return r;
    if (selectSteep(alloc, db, fqn, null) catch null) |r| return r;
    return null;
}

/// True when `s` is a plain class reference (`Foo`, `A::B`) usable as a
/// member-lookup key — i.e. `stripWrapper` fully reduced it. Rejects residue
/// like `T.untyped`, `T.any(A, B)`, `Boolean?`, or anything with spaces/parens
/// so the caller can fall back to its heuristics instead of a dead lookup.
pub fn isBareClassRef(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isUpper(s[0])) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != ':') return false;
    }
    return true;
}

/// Resolve a `Class#method` query through the chain. Convenience wrapper
/// that calls `resolve` and strips `Class<X>` wrappers from the type_str
/// before returning. Caller frees `result.type_str`.
pub fn resolveMethodOnClass(
    alloc: std.mem.Allocator,
    db: db_mod.Db,
    class_fqn: []const u8,
    method_name: []const u8,
) ?TypeResult {
    return resolve(alloc, db, class_fqn, method_name, -1);
}

test "resolve picks sorbet over oracle when both present" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO sorbet_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('Foo','class','SorbetType','sorbet',95,100)");
    try db.exec("INSERT INTO type_oracle(fqn, type_str, source, confidence) VALUES('Foo','OracleType','rbs',70)");

    var r = resolve(alloc, db, "Foo", null, -1) orelse return error.NoMatch;
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("SorbetType", r.type_str);
    try std.testing.expectEqual(Source.sorbet, r.source);
}

test "isBareClassRef accepts plain refs, rejects sorbet residue" {
    try std.testing.expect(isBareClassRef("User"));
    try std.testing.expect(isBareClassRef("Foo::Bar"));
    try std.testing.expect(!isBareClassRef("T.untyped"));
    try std.testing.expect(!isBareClassRef("T.any(String, Integer)"));
    try std.testing.expect(!isBareClassRef("user"));
    try std.testing.expect(!isBareClassRef(""));
    try std.testing.expect(!isBareClassRef("Array[Foo]"));
}

test "resolveExternalOracle: sorbet≥80 then steep, else null; feeds stripWrapper" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    // Miss on empty tables (the plain-Ruby case).
    try std.testing.expect(resolveExternalOracle(alloc, db, "Nope") == null);

    // Sorbet hit (conf≥80), stored as raw Sorbet syntax.
    try db.exec("INSERT INTO sorbet_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('acct','var','T.nilable(Account)','sorbet:hover',90,100)");
    var r = resolveExternalOracle(alloc, db, "acct") orelse return error.NoMatch;
    defer r.deinit(alloc);
    try std.testing.expectEqual(Source.sorbet, r.source);
    const bare = try stripWrapper(alloc, r.type_str);
    defer alloc.free(bare);
    try std.testing.expectEqualStrings("Account", bare);
    try std.testing.expect(isBareClassRef(bare));

    // Low-confidence sorbet is not surfaced.
    try db.exec("INSERT INTO sorbet_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('lowc','var','Foo','sorbet',50,100)");
    try std.testing.expect(resolveExternalOracle(alloc, db, "lowc") == null);
}

test "resolve falls through to literal when no high-confidence type" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO files(path) VALUES('a.rb')");
    try db.exec("INSERT INTO symbols(file_id, name, kind, line, col, return_type) VALUES(1,'compute','def',1,0,'Integer')");

    var r = resolve(alloc, db, "compute", null, -1) orelse return error.NoMatch;
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("Integer", r.type_str);
    try std.testing.expectEqual(Source.literal, r.source);
}

test "stripWrapper unwraps Class<X>, T.nilable(X), generics" {
    const alloc = std.testing.allocator;
    {
        const s = try stripWrapper(alloc, "Class<User>");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("User", s);
    }
    {
        const s = try stripWrapper(alloc, "T.nilable(Order)");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("Order", s);
    }
    {
        const s = try stripWrapper(alloc, "Array[Item]");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("Array", s);
    }
    {
        const s = try stripWrapper(alloc, "Hash<Symbol, Object>");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("Hash", s);
    }
    {
        const s = try stripWrapper(alloc, "  String  ");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("String", s);
    }
}

test "stripWrapper unwraps T::Array[X] / T::Hash[K, V] / T::Set[X]" {
    const alloc = std.testing.allocator;
    {
        const s = try stripWrapper(alloc, "T::Array[User]");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("Array", s);
    }
    {
        const s = try stripWrapper(alloc, "T::Hash[Symbol, String]");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("Hash", s);
    }
    {
        const s = try stripWrapper(alloc, "T::Set[Integer]");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("Set", s);
    }
}

test "stripWrapper iterates nested wrappers to fixpoint" {
    const alloc = std.testing.allocator;
    {
        const s = try stripWrapper(alloc, "T.nilable(T::Array[T.nilable(String)])");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("Array", s);
    }
    {
        const s = try stripWrapper(alloc, "Class<T.nilable(User)>");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("User", s);
    }
    {
        const s = try stripWrapper(alloc, "T.must(T.nilable(Order))");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("Order", s);
    }
}

test "stripWrapper passes through bare names and unknown wrappers safely" {
    const alloc = std.testing.allocator;
    {
        const s = try stripWrapper(alloc, "User");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("User", s);
    }
    {
        const s = try stripWrapper(alloc, "");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("", s);
    }
}

test "resolveMethodOnClass surfaces sorbet method type" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO sorbet_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('User#name','method','String','sorbet:hover',95,100)");

    var r = resolveMethodOnClass(alloc, db, "User", "name") orelse return error.NoMatch;
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("String", r.type_str);
    try std.testing.expectEqual(Source.sorbet, r.source);
}

test "resolve drops sorbet result below threshold" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO sorbet_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('LowConf','class','LowType','sorbet',50,100)");

    const r = resolve(alloc, db, "LowConf", null, -1);
    try std.testing.expect(r == null);
}
