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
    else if (std.mem.eql(u8, class_name, "ActiveSupport::Duration"))
        &[_][]const u8{ "from_now", "ago", "since", "until", "before", "after", "to_i", "to_f", "seconds", "in_seconds", "in_minutes", "in_hours", "in_days", "in_weeks", "in_months", "in_years", "parts", "value", "inspect" }
    else if (std.mem.eql(u8, class_name, "Time") or std.mem.eql(u8, class_name, "ActiveSupport::TimeWithZone") or std.mem.eql(u8, class_name, "DateTime"))
        &[_][]const u8{ "year", "month", "day", "hour", "min", "sec", "wday", "yday", "mday", "to_date", "to_time", "to_i", "to_f", "to_s", "iso8601", "strftime", "beginning_of_day", "end_of_day", "beginning_of_month", "end_of_month", "beginning_of_week", "end_of_week", "midnight", "noon", "tomorrow", "yesterday", "next_day", "prev_day", "since", "ago", "advance", "change", "in_time_zone", "utc", "localtime", "zone", "monday?", "sunday?", "today?", "past?", "future?", "before?", "after?", "between?" }
    else if (std.mem.eql(u8, class_name, "Date"))
        &[_][]const u8{ "year", "month", "day", "wday", "yday", "cwday", "to_date", "to_time", "to_s", "iso8601", "strftime", "beginning_of_month", "end_of_month", "beginning_of_week", "beginning_of_year", "end_of_year", "next_day", "prev_day", "next_month", "prev_month", "tomorrow", "yesterday", "since", "ago", "advance", "change", "monday?", "sunday?", "leap?", "future?", "past?", "before?", "after?" }
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

// Rails/ActiveSupport request-cycle helpers that are method calls (not locals or
// indexed constants) returning gem types absent from the index. `params`,
// `request`, etc. otherwise complete nothing. Curated member sets — biased to the
// methods real code actually calls — let completion offer them. Completion-only:
// never persisted, so diagnostics/refs/hover are untouched.
pub fn isFrameworkReceiver(name: []const u8) bool {
    return frameworkMembers(name) != null;
}

fn frameworkMembers(name: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, name, "params"))
        return &[_][]const u8{ "require", "permit", "permit!", "fetch", "dig", "[]", "to_h", "to_unsafe_h", "key?", "has_key?", "keys", "values", "each", "merge", "slice", "except", "expect", "delete", "extract!", "transform_keys", "transform_values", "empty?", "include?", "as_json" };
    if (std.mem.eql(u8, name, "request"))
        return &[_][]const u8{ "headers", "body", "params", "method", "request_method", "get?", "post?", "put?", "patch?", "delete?", "head?", "path", "fullpath", "url", "original_url", "host", "domain", "port", "protocol", "scheme", "ssl?", "xhr?", "format", "content_type", "media_type", "remote_ip", "ip", "referer", "referrer", "user_agent", "query_parameters", "request_parameters", "query_string", "cookies", "session", "env", "authorization", "raw_post", "GET", "POST" };
    if (std.mem.eql(u8, name, "response"))
        return &[_][]const u8{ "status", "status=", "headers", "header", "body", "body=", "content_type", "content_type=", "media_type", "location", "location=", "set_header", "get_header", "cookies", "set_cookie", "delete_cookie", "successful?", "redirect?", "cache_control", "etag=", "charset" };
    if (std.mem.eql(u8, name, "cookies"))
        return &[_][]const u8{ "[]", "[]=", "signed", "encrypted", "permanent", "delete", "key?", "fetch", "to_hash", "each", "clear", "update" };
    if (std.mem.eql(u8, name, "session"))
        return &[_][]const u8{ "[]", "[]=", "delete", "clear", "keys", "values", "fetch", "key?", "has_key?", "id", "each", "to_hash", "destroy", "merge!", "dig", "empty?" };
    if (std.mem.eql(u8, name, "headers"))
        return &[_][]const u8{ "[]", "[]=", "fetch", "key?", "include?", "each", "merge!", "delete", "env", "to_h", "add" };
    if (std.mem.eql(u8, name, "flash"))
        return &[_][]const u8{ "[]", "[]=", "now", "keep", "discard", "notice", "notice=", "alert", "alert=", "key?", "each", "clear", "to_hash", "delete" };
    if (std.mem.eql(u8, name, "logger"))
        return &[_][]const u8{ "debug", "info", "warn", "error", "fatal", "unknown", "level", "level=", "debug?", "info?", "warn?", "error?", "tagged", "add", "formatter", "silence" };
    // ActiveModel::Errors — `model.errors.add(:base, ...)`, `.full_messages`.
    if (std.mem.eql(u8, name, "errors"))
        return &[_][]const u8{ "add", "added?", "clear", "delete", "full_messages", "full_messages_for", "full_message", "messages", "messages_for", "details", "each", "empty?", "any?", "blank?", "present?", "include?", "key?", "has_key?", "of_kind?", "size", "count", "[]", "attribute_names", "where", "group_by_attribute", "to_hash", "to_a", "as_json", "import", "merge!", "objects" };
    // ActiveSupport::Cache::Store — `Rails.cache.fetch(...)`, `cache.write`.
    if (std.mem.eql(u8, name, "cache"))
        return &[_][]const u8{ "read", "write", "fetch", "delete", "exist?", "read_multi", "write_multi", "fetch_multi", "delete_matched", "delete_multi", "increment", "decrement", "clear", "cleanup", "mute", "silence!", "read_entry", "write_entry" };
    return null;
}

pub fn addFrameworkCompletions(w: *std.Io.Writer, name: []const u8, first_item: *bool, line: u32, character: u32) !void {
    const methods = frameworkMembers(name) orelse return;
    for (methods) |m| {
        if (!first_item.*) try w.writeByte(',');
        first_item.* = false;
        try w.writeAll("{\"label\":");
        try writeEscapedJson(w, m);
        try w.print(",\"kind\":3,\"detail\":\"(rails)\",\"sortText\":\"1_", .{});
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
