const std = @import("std");
const type_resolver = @import("../lsp/type_resolver.zig");
const db_mod = @import("../db.zig");

test "P52 T52.1 resolveFromRbs surfaces param type_hint from RBS via selectParam path" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO files(path) VALUES('a.rb')");
    try db.exec("INSERT INTO symbols(file_id, name, kind, line, col, parent_name) VALUES(1,'process','def',1,0,'Worker')");
    try db.exec("INSERT INTO params(symbol_id, position, name, kind, type_hint, confidence) VALUES(1, 0, 'count', 'required', 'Integer', 90)");

    var r = type_resolver.resolve(alloc, db, "Worker", "process", 0) orelse return error.NoMatch;
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("Integer", r.type_str);
    try std.testing.expectEqual(type_resolver.Source.rbs_param, r.source);
    try std.testing.expectEqual(@as(u8, 90), r.confidence);
}

test "P52 T52.2 resolveFromYard surfaces return_type via selectLiteral fallback" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO files(path) VALUES('a.rb')");
    try db.exec("INSERT INTO symbols(file_id, name, kind, line, col, return_type) VALUES(1,'normalize','def',1,0,'String')");

    var r = type_resolver.resolve(alloc, db, "normalize", null, -1) orelse return error.NoMatch;
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("String", r.type_str);
    try std.testing.expectEqual(type_resolver.Source.literal, r.source);
}

test "P52 T52.3 resolveSorbet wins over steep when both exceed threshold" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO sorbet_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('M#m','method','SorbetT','sorbet',90,200)");
    try db.exec("INSERT INTO steep_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('M#m','method','SteepT','steep',95,100)");

    var r = type_resolver.resolveMethodOnClass(alloc, db, "M", "m") orelse return error.NoMatch;
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("SorbetT", r.type_str);
    try std.testing.expectEqual(type_resolver.Source.sorbet, r.source);
}

test "P52 T52.4 resolveTypeHint respects 80 confidence floor on sorbet/steep" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO sorbet_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('X','class','LowSorbet','sorbet',70,100)");
    try db.exec("INSERT INTO steep_results(fqn, kind, type_str, source, confidence, ts_us) VALUES('X','class','LowSteep','steep',75,100)");
    try db.exec("INSERT INTO type_oracle(fqn, type_str, source, confidence) VALUES('X','OracleType','rbs',60)");

    var r = type_resolver.resolve(alloc, db, "X", null, -1) orelse return error.NoMatch;
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("OracleType", r.type_str);
    try std.testing.expectEqual(type_resolver.Source.type_oracle, r.source);
}

test "P52 T52.5 stripWrapper canonicalises string literal generic wrappers" {
    const alloc = std.testing.allocator;
    const s = try type_resolver.stripWrapper(alloc, "Array[String]");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("Array", s);
}

test "P52 T52.6 stripWrapper canonicalises numeric literal Integer wrappers" {
    const alloc = std.testing.allocator;
    const s = try type_resolver.stripWrapper(alloc, "T.nilable(Integer)");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("Integer", s);
}

test "P52 T52.7 resolveNilUnion strips outer T.nilable wrapping" {
    const alloc = std.testing.allocator;
    const s = try type_resolver.stripWrapper(alloc, "T.nilable(User)");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("User", s);
}

test "P52 T52.8 lookupRBS via type_oracle returns expected param type" {
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    try db.exec("INSERT INTO type_oracle(fqn, method_name, param_pos, type_str, source, confidence) VALUES('String','split',0,'String','rbs',80)");

    var r = type_resolver.resolve(alloc, db, "String", "split", 0) orelse return error.NoMatch;
    defer r.deinit(alloc);
    try std.testing.expectEqualStrings("String", r.type_str);
    try std.testing.expectEqual(type_resolver.Source.type_oracle, r.source);
}
