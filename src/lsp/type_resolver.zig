const std = @import("std");
const db_mod = @import("../db.zig");

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
    if (selectOracle(alloc, db, fqn, method_name, param_pos) catch null) |r| return r;
    if (method_name) |mn| {
        if (selectParam(alloc, db, fqn, mn, param_pos) catch null) |r| return r;
    }
    if (selectLiteral(alloc, db, fqn) catch null) |r| return r;
    return null;
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
    return TypeResult{ .type_str = t, .source = .sorbet, .confidence = @intCast(stmt.column_int(1)) };
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
    return TypeResult{ .type_str = t, .source = .steep, .confidence = @intCast(stmt.column_int(1)) };
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
    return TypeResult{ .type_str = t, .source = .type_oracle, .confidence = @intCast(stmt.column_int(1)) };
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
    return TypeResult{ .type_str = t, .source = .rbs_param, .confidence = @intCast(stmt.column_int(1)) };
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
/// and generic parameters. Returns owned bytes the caller frees.
pub fn stripWrapper(alloc: std.mem.Allocator, type_str: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, type_str, " \t");
    if (std.mem.startsWith(u8, trimmed, "Class<") and std.mem.endsWith(u8, trimmed, ">")) {
        return try alloc.dupe(u8, trimmed["Class<".len .. trimmed.len - 1]);
    }
    if (std.mem.startsWith(u8, trimmed, "T.nilable(") and std.mem.endsWith(u8, trimmed, ")")) {
        return try alloc.dupe(u8, trimmed["T.nilable(".len .. trimmed.len - 1]);
    }
    const lbracket = std.mem.indexOfAny(u8, trimmed, "<[");
    if (lbracket) |idx| if (idx > 0) {
        return try alloc.dupe(u8, trimmed[0..idx]);
    };
    return try alloc.dupe(u8, trimmed);
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
