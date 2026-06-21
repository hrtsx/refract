const std = @import("std");

threadlocal var generic_return_buf: [256]u8 = undefined;

pub fn lookupStdlibReturn(class_name: []const u8, method_name: []const u8) ?[]const u8 {
    // Array-of-T unwrapping: [User].first → User, [User].count → Integer, etc.
    if (class_name.len > 2 and class_name[0] == '[' and class_name[class_name.len - 1] == ']') {
        const inner = class_name[1 .. class_name.len - 1];
        if (std.mem.eql(u8, method_name, "first") or std.mem.eql(u8, method_name, "last") or
            std.mem.eql(u8, method_name, "find") or std.mem.eql(u8, method_name, "take") or
            std.mem.eql(u8, method_name, "sample")) return inner;
        if (std.mem.eql(u8, method_name, "count") or std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "length")) return "Integer";
        if (std.mem.eql(u8, method_name, "empty?") or std.mem.eql(u8, method_name, "any?") or
            std.mem.eql(u8, method_name, "all?") or std.mem.eql(u8, method_name, "none?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "where") or std.mem.eql(u8, method_name, "order") or
            std.mem.eql(u8, method_name, "limit") or std.mem.eql(u8, method_name, "includes") or
            std.mem.eql(u8, method_name, "joins") or std.mem.eql(u8, method_name, "select") or
            std.mem.eql(u8, method_name, "preload") or std.mem.eql(u8, method_name, "eager_load") or
            std.mem.eql(u8, method_name, "distinct") or std.mem.eql(u8, method_name, "group") or
            std.mem.eql(u8, method_name, "having") or std.mem.eql(u8, method_name, "reorder") or
            std.mem.eql(u8, method_name, "rewhere") or std.mem.eql(u8, method_name, "unscoped") or
            std.mem.eql(u8, method_name, "scoped")) return class_name;
        if (std.mem.eql(u8, method_name, "map") or std.mem.eql(u8, method_name, "collect") or
            std.mem.eql(u8, method_name, "flat_map") or std.mem.eql(u8, method_name, "reject") or
            std.mem.eql(u8, method_name, "filter")) return "Array";
        if (std.mem.eql(u8, method_name, "to_a") or std.mem.eql(u8, method_name, "all")) return "Array";
        return null;
    }
    if (std.mem.startsWith(u8, class_name, "Array[") and class_name[class_name.len - 1] == ']') {
        const inner_type = class_name[6 .. class_name.len - 1];
        if (std.mem.eql(u8, method_name, "first") or std.mem.eql(u8, method_name, "last") or
            std.mem.eql(u8, method_name, "sample") or std.mem.eql(u8, method_name, "min") or
            std.mem.eql(u8, method_name, "max")) return inner_type;
        if (std.mem.eql(u8, method_name, "flatten") or std.mem.eql(u8, method_name, "compact") or
            std.mem.eql(u8, method_name, "uniq") or std.mem.eql(u8, method_name, "sort") or
            std.mem.eql(u8, method_name, "reverse") or std.mem.eql(u8, method_name, "shuffle")) return class_name;
        if (std.mem.eql(u8, method_name, "count") or std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "length")) return "Integer";
        if (std.mem.eql(u8, method_name, "empty?") or std.mem.eql(u8, method_name, "any?") or
            std.mem.eql(u8, method_name, "all?") or std.mem.eql(u8, method_name, "none?") or
            std.mem.eql(u8, method_name, "include?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "join")) return "String";
        if (std.mem.eql(u8, method_name, "to_a")) return class_name;
        return null;
    }
    if (std.mem.eql(u8, class_name, "String")) {
        if (std.mem.eql(u8, method_name, "upcase") or
            std.mem.eql(u8, method_name, "downcase") or
            std.mem.eql(u8, method_name, "strip") or
            std.mem.eql(u8, method_name, "lstrip") or
            std.mem.eql(u8, method_name, "rstrip") or
            std.mem.eql(u8, method_name, "chomp") or
            std.mem.eql(u8, method_name, "chop") or
            std.mem.eql(u8, method_name, "gsub") or
            std.mem.eql(u8, method_name, "sub") or
            std.mem.eql(u8, method_name, "capitalize") or
            std.mem.eql(u8, method_name, "swapcase") or
            std.mem.eql(u8, method_name, "reverse") or
            std.mem.eql(u8, method_name, "squeeze") or
            std.mem.eql(u8, method_name, "delete") or
            std.mem.eql(u8, method_name, "encode") or
            std.mem.eql(u8, method_name, "tr") or
            std.mem.eql(u8, method_name, "center") or
            std.mem.eql(u8, method_name, "ljust") or
            std.mem.eql(u8, method_name, "rjust") or
            std.mem.eql(u8, method_name, "concat") or
            std.mem.eql(u8, method_name, "prepend") or
            std.mem.eql(u8, method_name, "slice") or
            std.mem.eql(u8, method_name, "freeze") or
            std.mem.eql(u8, method_name, "to_s")) return "String";
        if (std.mem.eql(u8, method_name, "to_i") or
            std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "count") or
            std.mem.eql(u8, method_name, "bytesize") or
            std.mem.eql(u8, method_name, "hex") or
            std.mem.eql(u8, method_name, "oct")) return "Integer";
        if (std.mem.eql(u8, method_name, "to_f")) return "Float";
        if (std.mem.eql(u8, method_name, "to_sym")) return "Symbol";
        if (std.mem.eql(u8, method_name, "split") or
            std.mem.eql(u8, method_name, "chars") or
            std.mem.eql(u8, method_name, "bytes") or
            std.mem.eql(u8, method_name, "scan") or
            std.mem.eql(u8, method_name, "lines")) return "Array";
        if (std.mem.eql(u8, method_name, "empty?") or
            std.mem.eql(u8, method_name, "include?") or
            std.mem.eql(u8, method_name, "start_with?") or
            std.mem.eql(u8, method_name, "end_with?") or
            std.mem.eql(u8, method_name, "match?") or
            std.mem.eql(u8, method_name, "valid_encoding?")) return "TrueClass";
    }
    if (std.mem.eql(u8, class_name, "Integer") or
        std.mem.eql(u8, class_name, "Numeric"))
    {
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "inspect") or
            std.mem.eql(u8, method_name, "chr")) return "String";
        if (std.mem.eql(u8, method_name, "to_f")) return "Float";
        if (std.mem.eql(u8, method_name, "to_i") or
            std.mem.eql(u8, method_name, "abs") or
            std.mem.eql(u8, method_name, "ceil") or
            std.mem.eql(u8, method_name, "floor") or
            std.mem.eql(u8, method_name, "round") or
            std.mem.eql(u8, method_name, "truncate") or
            std.mem.eql(u8, method_name, "times") or
            std.mem.eql(u8, method_name, "gcd") or
            std.mem.eql(u8, method_name, "lcm") or
            std.mem.eql(u8, method_name, "next") or
            std.mem.eql(u8, method_name, "succ") or
            std.mem.eql(u8, method_name, "pred") or
            std.mem.eql(u8, method_name, "upto") or
            std.mem.eql(u8, method_name, "downto")) return "Integer";
        if (std.mem.eql(u8, method_name, "digits") or
            std.mem.eql(u8, method_name, "divmod")) return "Array";
        if (std.mem.eql(u8, method_name, "zero?") or
            std.mem.eql(u8, method_name, "odd?") or
            std.mem.eql(u8, method_name, "even?") or
            std.mem.eql(u8, method_name, "positive?") or
            std.mem.eql(u8, method_name, "negative?") or
            std.mem.eql(u8, method_name, "between?")) return "TrueClass";
    }
    if (std.mem.eql(u8, class_name, "Float")) {
        if (std.mem.eql(u8, method_name, "to_i") or
            std.mem.eql(u8, method_name, "ceil") or
            std.mem.eql(u8, method_name, "floor") or
            std.mem.eql(u8, method_name, "round") or
            std.mem.eql(u8, method_name, "truncate")) return "Integer";
        if (std.mem.eql(u8, method_name, "to_f") or
            std.mem.eql(u8, method_name, "abs")) return "Float";
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "positive?") or
            std.mem.eql(u8, method_name, "negative?") or
            std.mem.eql(u8, method_name, "zero?") or
            std.mem.eql(u8, method_name, "finite?") or
            std.mem.eql(u8, method_name, "nan?") or
            std.mem.eql(u8, method_name, "infinite?")) return "TrueClass";
    }
    if (std.mem.eql(u8, class_name, "Array")) {
        if (std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "count") or
            std.mem.eql(u8, method_name, "sum")) return "Integer";
        if (std.mem.eql(u8, method_name, "join")) return "String";
        if (std.mem.eql(u8, method_name, "empty?") or
            std.mem.eql(u8, method_name, "include?") or
            std.mem.eql(u8, method_name, "any?") or
            std.mem.eql(u8, method_name, "all?") or
            std.mem.eql(u8, method_name, "none?") or
            std.mem.eql(u8, method_name, "one?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "flatten") or
            std.mem.eql(u8, method_name, "compact") or
            std.mem.eql(u8, method_name, "uniq") or
            std.mem.eql(u8, method_name, "sort") or
            std.mem.eql(u8, method_name, "reverse") or
            std.mem.eql(u8, method_name, "map") or
            std.mem.eql(u8, method_name, "collect") or
            std.mem.eql(u8, method_name, "entries") or
            std.mem.eql(u8, method_name, "select") or
            std.mem.eql(u8, method_name, "filter") or
            std.mem.eql(u8, method_name, "reject") or
            std.mem.eql(u8, method_name, "push") or
            std.mem.eql(u8, method_name, "pop") or
            std.mem.eql(u8, method_name, "shift") or
            std.mem.eql(u8, method_name, "unshift") or
            std.mem.eql(u8, method_name, "append") or
            std.mem.eql(u8, method_name, "prepend") or
            std.mem.eql(u8, method_name, "shuffle") or
            std.mem.eql(u8, method_name, "rotate") or
            std.mem.eql(u8, method_name, "intersection") or
            std.mem.eql(u8, method_name, "union") or
            std.mem.eql(u8, method_name, "difference") or
            std.mem.eql(u8, method_name, "product") or
            std.mem.eql(u8, method_name, "combination") or
            std.mem.eql(u8, method_name, "permutation") or
            std.mem.eql(u8, method_name, "flat_map") or
            std.mem.eql(u8, method_name, "filter_map") or
            std.mem.eql(u8, method_name, "each_slice") or
            std.mem.eql(u8, method_name, "each_cons")) return "Array";
        if (std.mem.eql(u8, method_name, "tally") or
            std.mem.eql(u8, method_name, "to_h")) return "Hash";
    }
    if (std.mem.eql(u8, class_name, "Hash") or std.mem.startsWith(u8, class_name, "Hash[")) {
        if (std.mem.eql(u8, method_name, "keys")) {
            if (extractHashGenerics(class_name)) |g| {
                return std.fmt.bufPrint(&generic_return_buf, "Array[{s}]", .{g.key}) catch "Array";
            }
            return "Array";
        }
        if (std.mem.eql(u8, method_name, "values")) {
            if (extractHashGenerics(class_name)) |g| {
                return std.fmt.bufPrint(&generic_return_buf, "Array[{s}]", .{g.value}) catch "Array";
            }
            return "Array";
        }
        if (std.mem.eql(u8, method_name, "fetch") or std.mem.eql(u8, method_name, "[]") or std.mem.eql(u8, method_name, "dig")) {
            if (extractHashGenerics(class_name)) |g| return g.value;
            return null;
        }
        if (std.mem.eql(u8, method_name, "to_a") or
            std.mem.eql(u8, method_name, "map") or
            std.mem.eql(u8, method_name, "flat_map")) return "Array";
        if (std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "count")) return "Integer";
        if (std.mem.eql(u8, method_name, "empty?") or
            std.mem.eql(u8, method_name, "has_key?") or
            std.mem.eql(u8, method_name, "include?") or
            std.mem.eql(u8, method_name, "key?") or
            std.mem.eql(u8, method_name, "any?") or
            std.mem.eql(u8, method_name, "all?") or
            std.mem.eql(u8, method_name, "none?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "select") or
            std.mem.eql(u8, method_name, "filter") or
            std.mem.eql(u8, method_name, "reject") or
            std.mem.eql(u8, method_name, "merge") or
            std.mem.eql(u8, method_name, "merge!") or
            std.mem.eql(u8, method_name, "transform_values") or
            std.mem.eql(u8, method_name, "transform_keys") or
            std.mem.eql(u8, method_name, "invert") or
            std.mem.eql(u8, method_name, "compact") or
            std.mem.eql(u8, method_name, "slice") or
            std.mem.eql(u8, method_name, "except") or
            std.mem.eql(u8, method_name, "update") or
            std.mem.eql(u8, method_name, "each_with_object") or
            std.mem.eql(u8, method_name, "group_by") or
            std.mem.eql(u8, method_name, "each_key") or
            std.mem.eql(u8, method_name, "each_value") or
            std.mem.eql(u8, method_name, "each_pair")) return "Hash";
        if (std.mem.eql(u8, method_name, "to_s")) return "String";
    }
    if (std.mem.eql(u8, class_name, "Symbol")) {
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "id2name") or
            std.mem.eql(u8, method_name, "name") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "to_sym") or
            std.mem.eql(u8, method_name, "upcase") or
            std.mem.eql(u8, method_name, "downcase")) return "Symbol";
        if (std.mem.eql(u8, method_name, "to_proc")) return "Proc";
        if (std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size")) return "Integer";
        if (std.mem.eql(u8, method_name, "match?") or
            std.mem.eql(u8, method_name, "empty?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "match")) return "MatchData";
    }
    if (std.mem.eql(u8, class_name, "Regexp")) {
        if (std.mem.eql(u8, method_name, "match")) return "MatchData";
        if (std.mem.eql(u8, method_name, "source") or
            std.mem.eql(u8, method_name, "inspect") or
            std.mem.eql(u8, method_name, "to_s")) return "String";
        if (std.mem.eql(u8, method_name, "match?") or
            std.mem.eql(u8, method_name, "casefold?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "names") or
            std.mem.eql(u8, method_name, "named_captures")) return "Array";
        if (std.mem.eql(u8, method_name, "options")) return "Integer";
    }
    if (std.mem.eql(u8, class_name, "MatchData")) {
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "string") or
            std.mem.eql(u8, method_name, "pre_match") or
            std.mem.eql(u8, method_name, "post_match") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "captures") or
            std.mem.eql(u8, method_name, "to_a") or
            std.mem.eql(u8, method_name, "names")) return "Array";
        if (std.mem.eql(u8, method_name, "named_captures")) return "Hash";
        if (std.mem.eql(u8, method_name, "length") or
            std.mem.eql(u8, method_name, "size")) return "Integer";
        if (std.mem.eql(u8, method_name, "regexp")) return "Regexp";
    }
    if (std.mem.eql(u8, class_name, "File") or std.mem.eql(u8, class_name, "IO")) {
        if (std.mem.eql(u8, method_name, "read") or
            std.mem.eql(u8, method_name, "gets") or
            std.mem.eql(u8, method_name, "readline") or
            std.mem.eql(u8, method_name, "chomp") or
            std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "path") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "readlines") or
            std.mem.eql(u8, method_name, "each_line")) return "Array";
        if (std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "pos") or
            std.mem.eql(u8, method_name, "lineno") or
            std.mem.eql(u8, method_name, "fileno")) return "Integer";
        if (std.mem.eql(u8, method_name, "exist?") or
            std.mem.eql(u8, method_name, "file?") or
            std.mem.eql(u8, method_name, "directory?") or
            std.mem.eql(u8, method_name, "readable?") or
            std.mem.eql(u8, method_name, "writable?") or
            std.mem.eql(u8, method_name, "eof?") or
            std.mem.eql(u8, method_name, "closed?")) return "TrueClass";
        if (std.mem.eql(u8, method_name, "stat")) return "File::Stat";
    }
    if (std.mem.eql(u8, class_name, "Time") or std.mem.eql(u8, class_name, "Date") or
        std.mem.eql(u8, class_name, "DateTime"))
    {
        if (std.mem.eql(u8, method_name, "now") or
            std.mem.eql(u8, method_name, "today") or
            std.mem.eql(u8, method_name, "current") or
            std.mem.eql(u8, method_name, "new") or
            std.mem.eql(u8, method_name, "parse") or
            std.mem.eql(u8, method_name, "utc") or
            std.mem.eql(u8, method_name, "at") or
            std.mem.eql(u8, method_name, "yesterday") or
            std.mem.eql(u8, method_name, "tomorrow") or
            std.mem.eql(u8, method_name, "beginning_of_day") or
            std.mem.eql(u8, method_name, "end_of_day") or
            std.mem.eql(u8, method_name, "beginning_of_month") or
            std.mem.eql(u8, method_name, "end_of_month") or
            std.mem.eql(u8, method_name, "beginning_of_year") or
            std.mem.eql(u8, method_name, "ago") or
            std.mem.eql(u8, method_name, "since") or
            std.mem.eql(u8, method_name, "in_time_zone") or
            std.mem.eql(u8, method_name, "change") or
            std.mem.eql(u8, method_name, "advance")) return class_name;
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "strftime") or
            std.mem.eql(u8, method_name, "iso8601") or
            std.mem.eql(u8, method_name, "httpdate") or
            std.mem.eql(u8, method_name, "rfc2822") or
            std.mem.eql(u8, method_name, "to_formatted_s") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "to_i") or
            std.mem.eql(u8, method_name, "to_r") or
            std.mem.eql(u8, method_name, "year") or
            std.mem.eql(u8, method_name, "month") or
            std.mem.eql(u8, method_name, "day") or
            std.mem.eql(u8, method_name, "hour") or
            std.mem.eql(u8, method_name, "min") or
            std.mem.eql(u8, method_name, "sec") or
            std.mem.eql(u8, method_name, "wday") or
            std.mem.eql(u8, method_name, "yday") or
            std.mem.eql(u8, method_name, "usec") or
            std.mem.eql(u8, method_name, "nsec")) return "Integer";
        if (std.mem.eql(u8, method_name, "to_f")) return "Float";
        if (std.mem.eql(u8, method_name, "to_date")) return "Date";
        if (std.mem.eql(u8, method_name, "to_time")) return "Time";
        if (std.mem.eql(u8, method_name, "to_datetime")) return "DateTime";
        if (std.mem.eql(u8, method_name, "zone")) return "String";
        if (std.mem.eql(u8, method_name, "dst?") or
            std.mem.eql(u8, method_name, "utc?") or
            std.mem.eql(u8, method_name, "future?") or
            std.mem.eql(u8, method_name, "past?") or
            std.mem.eql(u8, method_name, "today?") or
            std.mem.eql(u8, method_name, "saturday?") or
            std.mem.eql(u8, method_name, "sunday?") or
            std.mem.eql(u8, method_name, "on_weekday?") or
            std.mem.eql(u8, method_name, "on_weekend?")) return "TrueClass";
    }
    if (std.mem.eql(u8, class_name, "Enumerator")) {
        if (std.mem.eql(u8, method_name, "to_a") or
            std.mem.eql(u8, method_name, "entries")) return "Array";
        if (std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "count")) return "Integer";
        if (std.mem.eql(u8, method_name, "inspect") or
            std.mem.eql(u8, method_name, "to_s")) return "String";
    }
    if (std.mem.eql(u8, class_name, "Range")) {
        if (std.mem.eql(u8, method_name, "to_a") or
            std.mem.eql(u8, method_name, "entries")) return "Array";
        if (std.mem.eql(u8, method_name, "size") or
            std.mem.eql(u8, method_name, "count") or
            std.mem.eql(u8, method_name, "min") or
            std.mem.eql(u8, method_name, "max")) return "Integer";
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "inspect")) return "String";
        if (std.mem.eql(u8, method_name, "include?") or
            std.mem.eql(u8, method_name, "cover?") or
            std.mem.eql(u8, method_name, "any?") or
            std.mem.eql(u8, method_name, "none?") or
            std.mem.eql(u8, method_name, "exclude_end?")) return "TrueClass";
    }
    if (std.mem.eql(u8, class_name, "Pathname")) {
        if (std.mem.eql(u8, method_name, "to_s") or
            std.mem.eql(u8, method_name, "to_path") or
            std.mem.eql(u8, method_name, "basename") or
            std.mem.eql(u8, method_name, "dirname") or
            std.mem.eql(u8, method_name, "extname") or
            std.mem.eql(u8, method_name, "expand_path") or
            std.mem.eql(u8, method_name, "realpath") or
            std.mem.eql(u8, method_name, "read")) return "String";
        if (std.mem.eql(u8, method_name, "join") or
            std.mem.eql(u8, method_name, "parent") or
            std.mem.eql(u8, method_name, "cleanpath") or
            std.mem.eql(u8, method_name, "relative_path_from") or
            std.mem.eql(u8, method_name, "sub_ext")) return "Pathname";
        if (std.mem.eql(u8, method_name, "children") or
            std.mem.eql(u8, method_name, "entries") or
            std.mem.eql(u8, method_name, "glob") or
            std.mem.eql(u8, method_name, "readlines")) return "Array";
        if (std.mem.eql(u8, method_name, "exist?") or
            std.mem.eql(u8, method_name, "file?") or
            std.mem.eql(u8, method_name, "directory?") or
            std.mem.eql(u8, method_name, "empty?") or
            std.mem.eql(u8, method_name, "absolute?") or
            std.mem.eql(u8, method_name, "relative?")) return "TrueClass";
    }
    // Universal methods present on all objects
    if (std.mem.eql(u8, method_name, "class")) return "Class";
    if (std.mem.eql(u8, method_name, "frozen?") or
        std.mem.eql(u8, method_name, "nil?") or
        std.mem.eql(u8, method_name, "is_a?") or
        std.mem.eql(u8, method_name, "kind_of?") or
        std.mem.eql(u8, method_name, "instance_of?") or
        std.mem.eql(u8, method_name, "respond_to?") or
        std.mem.eql(u8, method_name, "equal?") or
        std.mem.eql(u8, method_name, "eql?") or
        std.mem.eql(u8, method_name, "tainted?")) return "TrueClass";
    if (std.mem.eql(u8, method_name, "to_s") or
        std.mem.eql(u8, method_name, "inspect")) return "String";
    if (std.mem.eql(u8, method_name, "hash") or
        std.mem.eql(u8, method_name, "object_id")) return "Integer";
    if (std.mem.eql(u8, method_name, "dup") or
        std.mem.eql(u8, method_name, "clone") or
        std.mem.eql(u8, method_name, "freeze") or
        std.mem.eql(u8, method_name, "itself") or
        std.mem.eql(u8, method_name, "tap")) return class_name;
    if (std.mem.eql(u8, method_name, "methods") or
        std.mem.eql(u8, method_name, "public_methods") or
        std.mem.eql(u8, method_name, "private_methods") or
        std.mem.eql(u8, method_name, "protected_methods") or
        std.mem.eql(u8, method_name, "instance_variables")) return "Array";
    // String methods missed earlier
    if (std.mem.eql(u8, class_name, "String")) {
        if (std.mem.eql(u8, method_name, "match")) return "MatchData";
        if (std.mem.eql(u8, method_name, "index") or
            std.mem.eql(u8, method_name, "rindex")) return "Integer";
        if (std.mem.eql(u8, method_name, "replace") or
            std.mem.eql(u8, method_name, "insert") or
            std.mem.eql(u8, method_name, "force_encoding") or
            std.mem.eql(u8, method_name, "scrub") or
            std.mem.eql(u8, method_name, "unicode_normalize") or
            std.mem.eql(u8, method_name, "b")) return "String";
        if (std.mem.eql(u8, method_name, "unpack")) return "Array";
        if (std.mem.eql(u8, method_name, "encoding")) return "Encoding";
    }
    // ActiveSupport methods — harmless on non-Rails codebases
    if (std.mem.eql(u8, method_name, "blank?") or
        std.mem.eql(u8, method_name, "present?") or
        std.mem.eql(u8, method_name, "in?")) return "TrueClass";
    if (std.mem.eql(u8, method_name, "with_indifferent_access") or
        std.mem.eql(u8, method_name, "deep_symbolize_keys") or
        std.mem.eql(u8, method_name, "deep_stringify_keys")) return "Hash";
    if (std.mem.eql(u8, method_name, "presence")) return class_name;
    if (std.mem.eql(u8, method_name, "try") or
        std.mem.eql(u8, method_name, "try!")) return null;
    return null;
}

fn extractHashGenerics(class_name: []const u8) ?struct { key: []const u8, value: []const u8 } {
    if (!std.mem.startsWith(u8, class_name, "Hash[")) return null;
    if (class_name[class_name.len - 1] != ']') return null;
    const inner = class_name[5 .. class_name.len - 1];
    var depth: u32 = 0;
    for (inner, 0..) |ch, i| {
        switch (ch) {
            '[' => depth += 1,
            ']' => depth -|= 1,
            ',' => if (depth == 0) return .{
                .key = std.mem.trim(u8, inner[0..i], " "),
                .value = std.mem.trim(u8, inner[i + 1 ..], " "),
            },
            else => {},
        }
    }
    return null;
}
