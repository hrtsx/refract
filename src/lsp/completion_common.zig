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

