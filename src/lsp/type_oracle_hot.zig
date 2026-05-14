const std = @import("std");

/// Curated allowlist of `(Class, method) → return_type` for the hottest stdlib
/// chain heads. Consulted before SQL in `type_resolver.resolve()` so the common
/// path skips prepare/bind/step entirely.
///
/// Keep this list short and high-signal: every entry costs O(1) cache + a
/// branch on the linear scan below. Only add chain heads that are common in
/// real Ruby code AND whose return type is canonical (no overload ambiguity).
const Entry = struct {
    fqn: []const u8,
    method: []const u8,
    return_type: []const u8,
};

const HOT_ENTRIES = [_]Entry{
    // String — most common chain head in Ruby code.
    .{ .fqn = "String", .method = "upcase", .return_type = "String" },
    .{ .fqn = "String", .method = "downcase", .return_type = "String" },
    .{ .fqn = "String", .method = "capitalize", .return_type = "String" },
    .{ .fqn = "String", .method = "strip", .return_type = "String" },
    .{ .fqn = "String", .method = "chomp", .return_type = "String" },
    .{ .fqn = "String", .method = "chop", .return_type = "String" },
    .{ .fqn = "String", .method = "reverse", .return_type = "String" },
    .{ .fqn = "String", .method = "to_s", .return_type = "String" },
    .{ .fqn = "String", .method = "to_str", .return_type = "String" },
    .{ .fqn = "String", .method = "to_sym", .return_type = "Symbol" },
    .{ .fqn = "String", .method = "to_i", .return_type = "Integer" },
    .{ .fqn = "String", .method = "to_f", .return_type = "Float" },
    .{ .fqn = "String", .method = "split", .return_type = "Array" },
    .{ .fqn = "String", .method = "chars", .return_type = "Array" },
    .{ .fqn = "String", .method = "lines", .return_type = "Array" },
    .{ .fqn = "String", .method = "bytes", .return_type = "Array" },
    .{ .fqn = "String", .method = "length", .return_type = "Integer" },
    .{ .fqn = "String", .method = "size", .return_type = "Integer" },
    .{ .fqn = "String", .method = "empty?", .return_type = "Boolean" },
    .{ .fqn = "String", .method = "include?", .return_type = "Boolean" },
    .{ .fqn = "String", .method = "start_with?", .return_type = "Boolean" },
    .{ .fqn = "String", .method = "end_with?", .return_type = "Boolean" },
    .{ .fqn = "String", .method = "match", .return_type = "MatchData" },
    .{ .fqn = "String", .method = "match?", .return_type = "Boolean" },

    // Array — second most common chain head.
    .{ .fqn = "Array", .method = "map", .return_type = "Array" },
    .{ .fqn = "Array", .method = "collect", .return_type = "Array" },
    .{ .fqn = "Array", .method = "select", .return_type = "Array" },
    .{ .fqn = "Array", .method = "filter", .return_type = "Array" },
    .{ .fqn = "Array", .method = "reject", .return_type = "Array" },
    .{ .fqn = "Array", .method = "compact", .return_type = "Array" },
    .{ .fqn = "Array", .method = "flatten", .return_type = "Array" },
    .{ .fqn = "Array", .method = "uniq", .return_type = "Array" },
    .{ .fqn = "Array", .method = "sort", .return_type = "Array" },
    .{ .fqn = "Array", .method = "reverse", .return_type = "Array" },
    .{ .fqn = "Array", .method = "to_a", .return_type = "Array" },
    .{ .fqn = "Array", .method = "to_h", .return_type = "Hash" },
    .{ .fqn = "Array", .method = "join", .return_type = "String" },
    .{ .fqn = "Array", .method = "length", .return_type = "Integer" },
    .{ .fqn = "Array", .method = "size", .return_type = "Integer" },
    .{ .fqn = "Array", .method = "count", .return_type = "Integer" },
    .{ .fqn = "Array", .method = "empty?", .return_type = "Boolean" },
    .{ .fqn = "Array", .method = "include?", .return_type = "Boolean" },
    .{ .fqn = "Array", .method = "any?", .return_type = "Boolean" },
    .{ .fqn = "Array", .method = "all?", .return_type = "Boolean" },
    .{ .fqn = "Array", .method = "none?", .return_type = "Boolean" },
    .{ .fqn = "Array", .method = "sum", .return_type = "Integer" },
    .{ .fqn = "Array", .method = "min", .return_type = "Object" },
    .{ .fqn = "Array", .method = "max", .return_type = "Object" },

    // Hash — third most common chain head.
    .{ .fqn = "Hash", .method = "keys", .return_type = "Array" },
    .{ .fqn = "Hash", .method = "values", .return_type = "Array" },
    .{ .fqn = "Hash", .method = "to_a", .return_type = "Array" },
    .{ .fqn = "Hash", .method = "to_h", .return_type = "Hash" },
    .{ .fqn = "Hash", .method = "merge", .return_type = "Hash" },
    .{ .fqn = "Hash", .method = "invert", .return_type = "Hash" },
    .{ .fqn = "Hash", .method = "map", .return_type = "Array" },
    .{ .fqn = "Hash", .method = "select", .return_type = "Hash" },
    .{ .fqn = "Hash", .method = "filter", .return_type = "Hash" },
    .{ .fqn = "Hash", .method = "reject", .return_type = "Hash" },
    .{ .fqn = "Hash", .method = "length", .return_type = "Integer" },
    .{ .fqn = "Hash", .method = "size", .return_type = "Integer" },
    .{ .fqn = "Hash", .method = "count", .return_type = "Integer" },
    .{ .fqn = "Hash", .method = "empty?", .return_type = "Boolean" },
    .{ .fqn = "Hash", .method = "key?", .return_type = "Boolean" },
    .{ .fqn = "Hash", .method = "has_key?", .return_type = "Boolean" },
    .{ .fqn = "Hash", .method = "include?", .return_type = "Boolean" },
    .{ .fqn = "Hash", .method = "value?", .return_type = "Boolean" },
    .{ .fqn = "Hash", .method = "fetch", .return_type = "Object" },

    // Symbol — chain head for AR / DSL receivers.
    .{ .fqn = "Symbol", .method = "to_s", .return_type = "String" },
    .{ .fqn = "Symbol", .method = "to_sym", .return_type = "Symbol" },
    .{ .fqn = "Symbol", .method = "to_proc", .return_type = "Proc" },
    .{ .fqn = "Symbol", .method = "length", .return_type = "Integer" },
    .{ .fqn = "Symbol", .method = "size", .return_type = "Integer" },
    .{ .fqn = "Symbol", .method = "upcase", .return_type = "Symbol" },
    .{ .fqn = "Symbol", .method = "downcase", .return_type = "Symbol" },

    // Integer / Float / Numeric — frequent on attribute hovers.
    .{ .fqn = "Integer", .method = "to_s", .return_type = "String" },
    .{ .fqn = "Integer", .method = "to_i", .return_type = "Integer" },
    .{ .fqn = "Integer", .method = "to_f", .return_type = "Float" },
    .{ .fqn = "Integer", .method = "zero?", .return_type = "Boolean" },
    .{ .fqn = "Integer", .method = "positive?", .return_type = "Boolean" },
    .{ .fqn = "Integer", .method = "negative?", .return_type = "Boolean" },
    .{ .fqn = "Integer", .method = "abs", .return_type = "Integer" },
    .{ .fqn = "Integer", .method = "succ", .return_type = "Integer" },
    .{ .fqn = "Integer", .method = "pred", .return_type = "Integer" },
    .{ .fqn = "Float", .method = "to_s", .return_type = "String" },
    .{ .fqn = "Float", .method = "to_i", .return_type = "Integer" },
    .{ .fqn = "Float", .method = "to_f", .return_type = "Float" },
    .{ .fqn = "Float", .method = "round", .return_type = "Integer" },
    .{ .fqn = "Float", .method = "ceil", .return_type = "Integer" },
    .{ .fqn = "Float", .method = "floor", .return_type = "Integer" },

    // Object — universal methods.
    .{ .fqn = "Object", .method = "to_s", .return_type = "String" },
    .{ .fqn = "Object", .method = "inspect", .return_type = "String" },
    .{ .fqn = "Object", .method = "class", .return_type = "Class" },
    .{ .fqn = "Object", .method = "nil?", .return_type = "Boolean" },
    .{ .fqn = "Object", .method = "frozen?", .return_type = "Boolean" },
    .{ .fqn = "Object", .method = "freeze", .return_type = "Object" },
    .{ .fqn = "Object", .method = "dup", .return_type = "Object" },
    .{ .fqn = "Object", .method = "clone", .return_type = "Object" },
    .{ .fqn = "Object", .method = "tap", .return_type = "Object" },

    // NilClass — keeps nil-chain hovers accurate.
    .{ .fqn = "NilClass", .method = "to_s", .return_type = "String" },
    .{ .fqn = "NilClass", .method = "to_a", .return_type = "Array" },
    .{ .fqn = "NilClass", .method = "nil?", .return_type = "Boolean" },
    .{ .fqn = "NilClass", .method = "inspect", .return_type = "String" },

    // Time / Date — common AR attribute return types.
    .{ .fqn = "Time", .method = "to_s", .return_type = "String" },
    .{ .fqn = "Time", .method = "to_i", .return_type = "Integer" },
    .{ .fqn = "Time", .method = "to_date", .return_type = "Date" },
    .{ .fqn = "Time", .method = "year", .return_type = "Integer" },
    .{ .fqn = "Time", .method = "month", .return_type = "Integer" },
    .{ .fqn = "Time", .method = "day", .return_type = "Integer" },
    .{ .fqn = "Date", .method = "to_s", .return_type = "String" },
    .{ .fqn = "Date", .method = "to_time", .return_type = "Time" },
    .{ .fqn = "Date", .method = "year", .return_type = "Integer" },
    .{ .fqn = "Date", .method = "month", .return_type = "Integer" },
    .{ .fqn = "Date", .method = "day", .return_type = "Integer" },

    // Range — completion on `(1..5).` chain.
    .{ .fqn = "Range", .method = "to_a", .return_type = "Array" },
    .{ .fqn = "Range", .method = "map", .return_type = "Array" },
    .{ .fqn = "Range", .method = "min", .return_type = "Object" },
    .{ .fqn = "Range", .method = "max", .return_type = "Object" },
    .{ .fqn = "Range", .method = "size", .return_type = "Integer" },
    .{ .fqn = "Range", .method = "count", .return_type = "Integer" },
    .{ .fqn = "Range", .method = "first", .return_type = "Object" },
    .{ .fqn = "Range", .method = "last", .return_type = "Object" },
};

/// Linear scan of the hot allowlist. Returns null when no match.
/// Branch-predictable on the common path; ~100 entries is well under the
/// branch-target buffer and well under SQL prepare cost.
pub fn lookup(fqn: []const u8, method: []const u8) ?[]const u8 {
    for (HOT_ENTRIES) |e| {
        if (std.mem.eql(u8, e.fqn, fqn) and std.mem.eql(u8, e.method, method)) {
            return e.return_type;
        }
    }
    return null;
}

pub fn entryCount() usize {
    return HOT_ENTRIES.len;
}

test "lookup hits canonical stdlib chain heads" {
    try std.testing.expectEqualStrings("String", lookup("String", "upcase").?);
    try std.testing.expectEqualStrings("Array", lookup("String", "split").?);
    try std.testing.expectEqualStrings("Array", lookup("Hash", "keys").?);
    try std.testing.expectEqualStrings("Hash", lookup("Array", "to_h").?);
    try std.testing.expectEqualStrings("Symbol", lookup("Symbol", "to_sym").?);
    try std.testing.expectEqualStrings("Integer", lookup("Float", "ceil").?);
    try std.testing.expectEqualStrings("Boolean", lookup("Object", "nil?").?);
}

test "lookup returns null for non-stdlib or unknown method" {
    try std.testing.expect(lookup("User", "name") == null);
    try std.testing.expect(lookup("String", "bogus_method_that_does_not_exist") == null);
    try std.testing.expect(lookup("", "") == null);
}

test "table size remains bounded for linear-scan perf budget" {
    try std.testing.expect(entryCount() < 200);
}
