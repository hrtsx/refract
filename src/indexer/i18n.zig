const std = @import("std");
const db_mod = @import("../db.zig");

pub fn indexLocaleFile(db: db_mod.Db, file_id: i64, source: []const u8) void {
    // Delete existing i18n_keys for this file
    const del = db.prepare("DELETE FROM i18n_keys WHERE file_id=?") catch return;
    defer del.finalize();
    del.bind_int(1, file_id);
    _ = del.step() catch |e| {
        std.debug.print("{s}", .{"refract: i18n delete: "});
        std.debug.print("{s}", .{@errorName(e)});
        std.debug.print("{s}", .{"\n"});
    };

    const ins = db.prepare("INSERT INTO i18n_keys (key, value, locale, file_id) VALUES (?, ?, ?, ?)") catch return;
    defer ins.finalize();

    // YAML line-by-line parser using indent tracking
    // Tracks a key stack per indent level (2-space canonical, but handles any consistent indent)
    const MAX_DEPTH = 32;
    var key_stack: [MAX_DEPTH][256]u8 = undefined;
    var key_lens: [MAX_DEPTH]usize = [_]usize{0} ** MAX_DEPTH;
    var depth: usize = 0;
    var locale_buf: [64]u8 = undefined;
    var locale_len: usize = 2;
    @memcpy(locale_buf[0..2], "en");

    var lines = std.mem.splitScalar(u8, source, '\n');
    var indent_unit: usize = 0; // detected from first indented line

    while (lines.next()) |raw_line| {
        // Skip empty lines and comments
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Count leading spaces
        var spaces: usize = 0;
        while (spaces < line.len and line[spaces] == ' ') spaces += 1;

        // Detect indent unit from first indented non-comment line
        if (indent_unit == 0 and spaces > 0) indent_unit = spaces;

        const level: usize = if (indent_unit > 0) spaces / indent_unit else 0;

        // Trim the line content
        const content = std.mem.trim(u8, line, " \t");
        if (content.len == 0) continue;

        // Find the colon separator
        const colon_pos = std.mem.indexOf(u8, content, ":") orelse continue;

        // Extract key (strip surrounding quotes if present)
        var raw_key = std.mem.trim(u8, content[0..colon_pos], " \t\"'");
        if (raw_key.len == 0 or raw_key[0] == '!' or raw_key[0] == '*') continue;
        // Strip YAML anchor markers (&anchor) from key
        if (raw_key[0] == '&') raw_key = std.mem.trim(u8, raw_key[1..], " \t");
        if (raw_key.len == 0) continue;

        // Copy key into stack at this level
        if (level < MAX_DEPTH) {
            const kl = @min(raw_key.len, key_stack[level].len - 1);
            @memcpy(key_stack[level][0..kl], raw_key[0..kl]);
            key_lens[level] = kl;
            depth = level + 1;
        }

        // Extract value (after the colon)
        const after_colon = std.mem.trim(u8, content[colon_pos + 1 ..], " \t");
        const has_value = after_colon.len > 0 and after_colon[0] != '#';

        // At depth 0, the first key is the locale
        if (level == 0) {
            locale_len = @min(raw_key.len, locale_buf.len - 1);
            @memcpy(locale_buf[0..locale_len], raw_key[0..locale_len]);
            continue; // locale key itself isn't a completion item
        }

        // Only emit leaf nodes (has a non-empty value, or is the only entry at this level)
        if (!has_value) continue;

        // Build the flattened dot-path key (skip the locale level = level 0)
        var flat_buf: [512]u8 = undefined;
        var flat_len: usize = 0;
        for (1..depth) |d| {
            if (d > 1) {
                if (flat_len < flat_buf.len - 1) {
                    flat_buf[flat_len] = '.';
                    flat_len += 1;
                }
            }
            const seg = key_stack[d][0..key_lens[d]];
            const copy_len = @min(seg.len, flat_buf.len - flat_len);
            @memcpy(flat_buf[flat_len .. flat_len + copy_len], seg[0..copy_len]);
            flat_len += copy_len;
        }
        if (flat_len == 0) continue;
        const flat_key = flat_buf[0..flat_len];

        // Extract value string (strip quotes and inline comments)
        var value_str: []const u8 = after_colon;
        // Handle YAML alias references (*alias) as values
        if (value_str.len > 0 and value_str[0] == '*') {
            value_str = value_str; // store alias ref as-is for display
        } else if (value_str.len > 0 and (value_str[0] == '"' or value_str[0] == '\'')) {
            const quote_char = value_str[0];
            value_str = value_str[1..];
            if (std.mem.indexOfScalar(u8, value_str, quote_char)) |end| {
                value_str = value_str[0..end];
            }
        } else {
            // Strip inline comment
            if (std.mem.indexOf(u8, value_str, " #")) |comment| {
                value_str = std.mem.trimEnd(u8, value_str[0..comment], " \t");
            }
        }

        ins.reset();
        ins.bind_text(1, flat_key);
        if (value_str.len > 0) ins.bind_text(2, value_str) else ins.bind_null(2);
        ins.bind_text(3, locale_buf[0..locale_len]);
        ins.bind_int(4, file_id);
        _ = ins.step() catch |e| {
            std.debug.print("{s}", .{"refract: i18n insert: "});
            std.debug.print("{s}", .{@errorName(e)});
            std.debug.print("{s}", .{"\n"});
        };
    }
}
