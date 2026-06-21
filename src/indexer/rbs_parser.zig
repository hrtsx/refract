const std = @import("std");
const db_mod = @import("../db.zig");
const index = @import("index.zig");

fn resolveRbsSymbolId(db: db_mod.Db, file_id: i64, name: []const u8, kind: []const u8, line: i32) ?i64 {
    const stmt = db.prepare("SELECT id FROM symbols WHERE file_id=? AND name=? AND kind=? AND line=? LIMIT 1") catch return null;
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    if (stmt.step() catch false) return stmt.column_int(0);
    return null;
}

pub fn isRbsIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_')) return false;
    }
    return true;
}

fn findTopLevelArrow(s: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            '-' => {
                if (depth == 0 and s[i + 1] == '>') return i;
            },
            else => {},
        }
    }
    return null;
}

fn findMatchingParen(s: []const u8, lpar: usize) ?usize {
    var depth: i32 = 0;
    var i: usize = lpar;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn insertOneRbsParam(db: db_mod.Db, symbol_id: i64, position: u32, part_in: []const u8) void {
    var rest = std.mem.trim(u8, part_in, " \t");
    if (rest.len == 0) return;
    var kind: []const u8 = "positional";
    if (std.mem.startsWith(u8, rest, "**")) {
        kind = "keyword_rest";
        rest = std.mem.trim(u8, rest[2..], " \t");
    } else if (rest[0] == '*') {
        kind = "rest";
        rest = std.mem.trim(u8, rest[1..], " \t");
    } else if (rest[0] == '&') {
        kind = "block";
        rest = std.mem.trim(u8, rest[1..], " \t");
    } else if (rest[0] == '?') {
        kind = "optional";
        rest = std.mem.trim(u8, rest[1..], " \t");
    }

    var name_part: []const u8 = "";
    var type_part: []const u8 = rest;
    var depth: i32 = 0;
    var j: usize = 0;
    while (j < rest.len) : (j += 1) {
        const c = rest[j];
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ':' => {
                if (depth == 0) {
                    if (j + 1 < rest.len and rest[j + 1] == ':') {
                        j += 1;
                        continue;
                    }
                    if (j > 0 and rest[j - 1] == ':') continue;
                    const maybe_name = std.mem.trim(u8, rest[0..j], " \t");
                    if (isRbsIdent(maybe_name)) {
                        name_part = maybe_name;
                        type_part = std.mem.trim(u8, rest[j + 1 ..], " \t");
                        if (std.mem.eql(u8, kind, "positional") or std.mem.eql(u8, kind, "optional")) {
                            kind = if (std.mem.eql(u8, kind, "optional")) "keyword" else "keyword";
                        }
                    }
                    break;
                }
            },
            else => {},
        }
    }

    // Positional form `Type name`: last whitespace-separated token is the name if it's a lowercase ident.
    if (name_part.len == 0 and type_part.len > 0) {
        if (std.mem.lastIndexOfAny(u8, type_part, " \t")) |ws| {
            const trailing = std.mem.trim(u8, type_part[ws + 1 ..], " \t");
            if (isRbsIdent(trailing) and trailing.len > 0 and trailing[0] >= 'a' and trailing[0] <= 'z') {
                name_part = trailing;
                type_part = std.mem.trim(u8, type_part[0..ws], " \t");
            }
        }
    }

    var name_buf: [32]u8 = undefined;
    const name_final: []const u8 = if (name_part.len > 0)
        name_part
    else
        std.fmt.bufPrint(&name_buf, "arg{d}", .{position}) catch "arg";
    const type_hint: ?[]const u8 = if (type_part.len > 0) type_part else null;
    index.insertParam(db, symbol_id, position, name_final, kind, type_hint, 90) catch {};
}

fn parseRbsParamList(db: db_mod.Db, symbol_id: i64, param_list: []const u8) void {
    var position: u32 = 0;
    var start: usize = 0;
    var depth: i32 = 0;
    var i: usize = 0;
    while (i <= param_list.len) : (i += 1) {
        const at_end = i == param_list.len;
        if (!at_end) {
            switch (param_list[i]) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -= 1,
                else => {},
            }
        }
        if (at_end or (param_list[i] == ',' and depth == 0)) {
            const part = param_list[start..i];
            if (std.mem.trim(u8, part, " \t").len > 0) {
                insertOneRbsParam(db, symbol_id, position, part);
                position += 1;
            }
            start = i + 1;
        }
    }
}

fn setRbsDoc(db: db_mod.Db, sym_id: i64, doc: []const u8) void {
    if (doc.len == 0) return;
    const upd = db.prepare("UPDATE symbols SET doc = ? WHERE id = ? AND (doc IS NULL OR doc = '')") catch return;
    defer upd.finalize();
    upd.bind_text(1, doc);
    upd.bind_int(2, sym_id);
    _ = upd.step() catch {};
}

fn insertRbsSymbol(db: db_mod.Db, file_id: i64, kind: []const u8, name: []const u8, line: i32, col: u32, parent_name: ?[]const u8) !void {
    const stmt = try db.prepare(
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col, parent_name)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    if (parent_name) |pn| stmt.bind_text(6, pn) else stmt.bind_null(6);
    _ = try stmt.step();
}

fn insertRbsSymbolWithReturn(db: db_mod.Db, file_id: i64, kind: []const u8, name: []const u8, line: i32, col: u32, return_type: []const u8, parent_name: ?[]const u8) !void {
    const check = try db.prepare(
        \\SELECT id, return_type FROM symbols
        \\WHERE file_id = ? AND name = ? AND kind = ?
    );
    defer check.finalize();
    check.bind_int(1, file_id);
    check.bind_text(2, name);
    check.bind_text(3, kind);

    if (try check.step()) {
        const existing_rt = check.column_text(1);
        if (std.mem.eql(u8, existing_rt, return_type)) return;
        var dedup_it = std.mem.splitSequence(u8, existing_rt, " | ");
        var already_present = false;
        while (dedup_it.next()) |part| {
            if (std.mem.eql(u8, part, return_type)) {
                already_present = true;
                break;
            }
        }
        if (already_present) return;
        const id = check.column_int(0);
        var buf: [512]u8 = undefined;
        const aggregated = std.fmt.bufPrint(&buf, "{s} | {s}", .{ existing_rt, return_type }) catch return;
        const upd = try db.prepare("UPDATE symbols SET return_type = ? WHERE id = ?");
        defer upd.finalize();
        upd.bind_text(1, aggregated);
        upd.bind_int(2, id);
        _ = try upd.step();
        return;
    }

    const stmt = try db.prepare(
        \\INSERT OR IGNORE INTO symbols (file_id, name, kind, line, col, return_type, parent_name)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_text(2, name);
    stmt.bind_text(3, kind);
    stmt.bind_int(4, line);
    stmt.bind_int(5, @intCast(col));
    stmt.bind_text(6, return_type);
    if (parent_name) |pn| stmt.bind_text(7, pn) else stmt.bind_null(7);
    _ = try stmt.step();
}

pub fn indexRbs(db: db_mod.Db, file_id: i64, source: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_num: i32 = 1;
    var ns_stack: [32][]const u8 = undefined;
    var ns_indent: [32]usize = undefined;
    var ns_depth: u8 = 0;
    var ns_buf: [512]u8 = undefined;
    var doc_buf: [2048]u8 = undefined;
    var doc_len: usize = 0;

    while (lines.next()) |raw_line| : (line_num += 1) {
        const indent = raw_line.len - std.mem.trimStart(u8, raw_line, " \t").len;
        const line = std.mem.trim(u8, raw_line, " \t");

        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) {
            var content = line[1..];
            if (content.len > 0 and content[0] == ' ') content = content[1..];
            if (doc_len + content.len + 1 < doc_buf.len) {
                if (doc_len > 0) {
                    doc_buf[doc_len] = '\n';
                    doc_len += 1;
                }
                @memcpy(doc_buf[doc_len..][0..content.len], content);
                doc_len += content.len;
            }
            continue;
        }

        if (std.mem.eql(u8, line, "end")) {
            if (ns_depth > 0 and indent == ns_indent[ns_depth - 1]) ns_depth -= 1;
            doc_len = 0;
            continue;
        }

        if (std.mem.startsWith(u8, line, "class ") or std.mem.startsWith(u8, line, "module ")) {
            const kw_len: usize = if (line[0] == 'c') 6 else 7;
            const name_end = std.mem.indexOfScalar(u8, line[kw_len..], ' ') orelse line.len - kw_len;
            const name = line[kw_len .. kw_len + name_end];
            if (name.len == 0) continue;
            const kind: []const u8 = if (line[0] == 'c') "class" else "module";
            if (ns_depth < 32) {
                ns_stack[ns_depth] = name;
                ns_indent[ns_depth] = indent;
                ns_depth += 1;
            }
            insertRbsSymbol(db, file_id, kind, name, line_num, 0, null) catch |e| {
                std.debug.print("{s}", .{"refract: RBS insert: "});
                std.debug.print("{s}", .{@errorName(e)});
                std.debug.print("{s}", .{"\n"});
            };
            if (doc_len > 0) {
                if (resolveRbsSymbolId(db, file_id, name, kind, line_num)) |sid| {
                    setRbsDoc(db, sid, doc_buf[0..doc_len]);
                }
                doc_len = 0;
            }
            continue;
        }

        // Compute current parent name from namespace stack
        const current_parent: ?[]const u8 = if (ns_depth > 0) blk: {
            var pos: usize = 0;
            for (ns_stack[0..ns_depth], 0..) |ns, ni| {
                if (ni > 0) {
                    if (pos + 2 <= ns_buf.len) {
                        ns_buf[pos] = ':';
                        ns_buf[pos + 1] = ':';
                        pos += 2;
                    }
                }
                if (pos + ns.len <= ns_buf.len) {
                    @memcpy(ns_buf[pos..][0..ns.len], ns);
                    pos += ns.len;
                }
            }
            break :blk ns_buf[0..pos];
        } else null;

        if (std.mem.startsWith(u8, line, "def ")) {
            const rest = line[4..];
            const colon_pos = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const name = std.mem.trim(u8, rest[0..colon_pos], " ");
            if (name.len == 0) continue;
            const sig_part = rest[colon_pos + 1 ..];

            // RBS self.method → classdef kind, strip "self." prefix
            const is_class_method = std.mem.startsWith(u8, name, "self.");
            const def_kind: []const u8 = if (is_class_method) "classdef" else "def";
            const def_name = if (is_class_method) name[5..] else name;

            const arrow_opt = findTopLevelArrow(sig_part);
            if (arrow_opt == null) {
                insertRbsSymbol(db, file_id, def_kind, def_name, line_num, 0, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
                continue;
            }
            const arrow_pos = arrow_opt.?;
            const raw_rt = std.mem.trim(u8, sig_part[arrow_pos + 2 ..], " ");
            const rt = index.normalizeRbsReturn(raw_rt);
            if (rt.len > 0 and !std.mem.eql(u8, rt, "void")) {
                insertRbsSymbolWithReturn(db, file_id, def_kind, def_name, line_num, 0, rt, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            } else {
                insertRbsSymbol(db, file_id, def_kind, def_name, line_num, 0, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            }

            const before_arrow = sig_part[0..arrow_pos];
            if (std.mem.indexOfScalar(u8, before_arrow, '(')) |lpar| {
                if (findMatchingParen(before_arrow, lpar)) |rpar| {
                    const param_list = before_arrow[lpar + 1 .. rpar];
                    if (resolveRbsSymbolId(db, file_id, name, "def", line_num)) |sid| {
                        parseRbsParamList(db, sid, param_list);
                    }
                }
            }
            if (doc_len > 0) {
                if (resolveRbsSymbolId(db, file_id, def_name, def_kind, line_num)) |sid| {
                    setRbsDoc(db, sid, doc_buf[0..doc_len]);
                }
                doc_len = 0;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "interface ")) {
            const rest = line["interface ".len..];
            const end = std.mem.indexOfAny(u8, rest, " \t\r\n{") orelse rest.len;
            const name = std.mem.trim(u8, rest[0..end], " \t");
            if (name.len > 0)
                insertRbsSymbol(db, file_id, "module", name, line_num, 0, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            continue;
        }

        if (std.mem.startsWith(u8, line, "type ")) {
            const rest = line["type ".len..];
            const end = std.mem.indexOfAny(u8, rest, " \t\r\n=") orelse rest.len;
            const name = std.mem.trim(u8, rest[0..end], " \t");
            if (name.len > 0)
                insertRbsSymbol(db, file_id, "constant", name, line_num, 0, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            continue;
        }

        if (std.mem.startsWith(u8, line, "attr_reader ") or
            std.mem.startsWith(u8, line, "attr_writer ") or
            std.mem.startsWith(u8, line, "attr_accessor "))
        {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const rest = line[sp + 1 ..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
            const attr_name = std.mem.trim(u8, rest[0..colon], " ");
            if (attr_name.len == 0) continue;
            const raw_attr_rt = std.mem.trim(u8, rest[colon + 1 ..], " ");
            const rt = index.normalizeRbsReturn(raw_attr_rt);
            if (!std.mem.startsWith(u8, line, "attr_writer ")) {
                insertRbsSymbolWithReturn(db, file_id, "def", attr_name, line_num, 0, rt, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            }
            if (std.mem.startsWith(u8, line, "attr_writer ") or
                std.mem.startsWith(u8, line, "attr_accessor "))
            {
                var writer_buf: [256]u8 = undefined;
                const writer_name = std.fmt.bufPrint(&writer_buf, "{s}=", .{attr_name}) catch continue;
                insertRbsSymbol(db, file_id, "def", writer_name, line_num, 0, current_parent) catch |e| {
                    std.debug.print("{s}", .{"refract: RBS insert: "});
                    std.debug.print("{s}", .{@errorName(e)});
                    std.debug.print("{s}", .{"\n"});
                };
            }
            continue;
        }
    }
}
