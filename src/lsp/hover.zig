const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const erb_mapping = @import("erb_mapping.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractPosition = S.extractPosition;
const uriToPath = S.uriToPath;
const emptyResult = S.emptyResult;
const writeEscapedJsonContent = S.writeEscapedJsonContent;
const resolveRequireTarget = S.resolveRequireTarget;
const getLineSlice = S.getLineSlice;
const extractWord = S.extractWord;
const extractQualifiedName = S.extractQualifiedName;
const utf8ColToUtf16 = S.utf8ColToUtf16;

pub fn handleHover(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    self.flushDirtyUris();
    self.db_mutex.lockUncancelable(std.Options.debug_io);
    defer self.db_mutex.unlock(std.Options.debug_io);
    const indexing_in_progress = !self.bg_started_event.load(.acquire);
    const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
    const pos = extractPosition(msg.params) orelse return emptyResult(msg);
    const line: u32 = pos.line;
    const character: u32 = pos.character;

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch
        return emptyResult(msg);
    defer self.alloc.free(source);

    const offset = self.clientPosToOffset(source, line, character);

    if (std.mem.endsWith(u8, path, ".erb") and !erb_mapping.isErbRubyContext(source, offset))
        return emptyResult(msg);

    if (resolveRequireTarget(self.alloc, self.db, source, offset, path)) |target_path| {
        defer self.alloc.free(target_path);
        var rq_aw = std.Io.Writer.Allocating.init(self.alloc);
        const rq_w = &rq_aw.writer;
        try rq_w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"**Requires:** `");
        try writeEscapedJsonContent(rq_w, target_path);
        try rq_w.writeAll("`\"}");
        try rq_w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":999}}}}}}", .{ line, line });
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try rq_aw.toOwnedSlice(), .@"error" = null };
    }

    if (Server.detectI18nContext(source, offset)) {
        const hover_line_src = getLineSlice(source, line);
        var key_start = offset;
        while (key_start > 0 and source[key_start - 1] != '"' and source[key_start - 1] != '\'') {
            key_start -= 1;
        }
        if (key_start > 0) key_start -= 1;
        var key_end = offset;
        while (key_end < source.len and source[key_end] != '"' and source[key_end] != '\'') {
            key_end += 1;
        }
        const word_col_byte = if (key_start < hover_line_src.len) key_start else 0;
        const hover_wc16 = self.toClientCol(hover_line_src, word_col_byte);
        const hover_we16 = hover_wc16 + @as(u32, @intCast(key_end - key_start));
        return try hoverI18n(self, msg, source, offset, line, hover_wc16, hover_we16);
    }

    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    // Include sigil prefix for instance/class/global variables (@user, @@count, $stdout)
    const word_start = @intFromPtr(word.ptr) - @intFromPtr(source.ptr);
    var sigil_start = word_start;
    if (sigil_start > 0 and source[sigil_start - 1] == '@') {
        sigil_start -= 1;
        if (sigil_start > 0 and source[sigil_start - 1] == '@') sigil_start -= 1;
    } else if (sigil_start > 0 and source[sigil_start - 1] == '$') {
        sigil_start -= 1;
    }
    const lookup_word = source[sigil_start .. word_start + word.len];

    const hover_line_src = getLineSlice(source, line);
    const sigil_col_byte = if (sigil_start >= @intFromPtr(hover_line_src.ptr) - @intFromPtr(source.ptr))
        sigil_start - (@intFromPtr(hover_line_src.ptr) - @intFromPtr(source.ptr))
    else
        0;
    const hover_wc16 = self.toClientCol(hover_line_src, sigil_col_byte);
    const hover_we16 = utf8ColToUtf16(hover_line_src, @min(sigil_col_byte + lookup_word.len, hover_line_src.len));

    // Check local_vars first for concrete inferred types
    const cursor_line: i64 = @intCast(line + 1);
    const fstmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer fstmt.finalize();
    fstmt.bind_text(1, path);
    if (try fstmt.step()) {
        const fid = fstmt.column_int(0);
        const lv_stmt = try self.db.prepare("SELECT type_hint, is_block_param FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 10");
        defer lv_stmt.finalize();
        lv_stmt.bind_int(1, fid);
        lv_stmt.bind_text(2, lookup_word);
        lv_stmt.bind_int(3, cursor_line);
        var type_hints: [3][]u8 = undefined;
        var hint_count: usize = 0;
        var lv_is_block_param = false;
        var lv_first_row = true;
        while (try lv_stmt.step()) {
            if (lv_first_row) {
                lv_is_block_param = lv_stmt.column_int(1) != 0;
                lv_first_row = false;
            }
            const th = lv_stmt.column_text(0);
            var found = false;
            for (type_hints[0..hint_count]) |s| {
                if (std.mem.eql(u8, s, th)) {
                    found = true;
                    break;
                }
            }
            if (!found and hint_count < 3) {
                type_hints[hint_count] = self.alloc.dupe(u8, th) catch break;
                hint_count += 1;
            }
        }
        defer for (type_hints[0..hint_count]) |t| self.alloc.free(t);
        if (hint_count > 0) {
            var aw = std.Io.Writer.Allocating.init(self.alloc);
            const w = &aw.writer;
            try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
            if (lv_is_block_param) {
                try w.writeAll("*(block param)* `");
            } else {
                try w.writeByte('`');
            }
            try writeEscapedJsonContent(w, lookup_word);
            try w.writeAll("`: ");
            for (type_hints[0..hint_count], 0..) |th, ti| {
                if (ti > 0) try w.writeAll(" | ");
                try writeEscapedJsonContent(w, th);
            }
            try w.writeAll("\"}");
            try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ line, hover_wc16, line, hover_we16 });
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = try aw.toOwnedSlice(),
                .@"error" = null,
            };
        }
        // Check for untyped local var
        const lv_exist = try self.db.prepare("SELECT is_block_param FROM local_vars WHERE file_id=? AND name=? AND line<=? LIMIT 1");
        defer lv_exist.finalize();
        lv_exist.bind_int(1, fid);
        lv_exist.bind_text(2, lookup_word);
        lv_exist.bind_int(3, cursor_line);
        if (try lv_exist.step()) {
            const ibp = lv_exist.column_int(0) != 0;
            var aw_lv = std.Io.Writer.Allocating.init(self.alloc);
            const w_lv = &aw_lv.writer;
            try w_lv.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
            if (ibp) {
                try w_lv.writeAll("*(block param)* `");
            } else {
                try w_lv.writeAll("*(local variable)* `");
            }
            try writeEscapedJsonContent(w_lv, lookup_word);
            try w_lv.writeAll("\"}");
            try w_lv.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ line, hover_wc16, line, hover_we16 });
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = try aw_lv.toOwnedSlice(),
                .@"error" = null,
            };
        }
    }

    // Receiver-aware hover: detect receiver.method and look up method on receiver type
    const word_byte_start = @intFromPtr(word.ptr) - @intFromPtr(source.ptr);
    if (word_byte_start > 0 and source[word_byte_start - 1] == '.') {
        const recv_off = if (word_byte_start >= 2) word_byte_start - 2 else 0;
        const recv_w = extractWord(source, recv_off);
        if (recv_w.len > 0) {
            var recv_type: ?[]const u8 = null;
            if (std.ascii.isUpper(recv_w[0])) {
                recv_type = recv_w;
            } else if (try resolveHoverReceiverType(self, path, recv_w, line)) |rt| {
                recv_type = rt;
            }
            if (recv_type) |rt| {
                const base_type = if (rt.len > 2 and rt[0] == '[' and rt[rt.len - 1] == ']') rt[1 .. rt.len - 1] else rt;
                if (try hoverLookupOnClass(self, msg, word, base_type, line, hover_wc16, hover_we16)) |r| return r;
            }
        }
    }

    if (try hoverLookup(self, msg, word, path, line, hover_wc16, hover_we16)) |r| return r;

    const qualified = extractQualifiedName(source, offset);
    if (!std.mem.eql(u8, qualified, word)) {
        if (try hoverLookup(self, msg, qualified, path, line, hover_wc16, hover_we16)) |r| return r;
    }

    if (stdlibClassDoc(word)) |doc| {
        var aw_std = std.Io.Writer.Allocating.init(self.alloc);
        const w_std = &aw_std.writer;
        try w_std.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
        try writeEscapedJsonContent(w_std, doc);
        try w_std.writeAll("\"}");
        try w_std.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ line, hover_wc16, line, hover_we16 });
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_std.toOwnedSlice(), .@"error" = null };
    }

    if (indexing_in_progress) {
        var aw_busy = std.Io.Writer.Allocating.init(self.alloc);
        try aw_busy.writer.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"_(refract: indexing workspace — retry in a moment)_\"}}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_busy.toOwnedSlice(), .@"error" = null };
    }
    return emptyResult(msg);
}

fn stdlibClassDoc(name: []const u8) ?[]const u8 {
    const entries = .{
        .{ "Time", "*(class)* `Time` — Ruby core date/time class" },
        .{ "Date", "*(class)* `Date` — calendar date (require 'date')" },
        .{ "DateTime", "*(class)* `DateTime` — date + time with offset (require 'date')" },
        .{ "String", "*(class)* `String` — Ruby core string class" },
        .{ "Integer", "*(class)* `Integer` — Ruby core integer class" },
        .{ "Float", "*(class)* `Float` — Ruby core floating-point class" },
        .{ "Array", "*(class)* `Array` — Ruby core ordered collection" },
        .{ "Hash", "*(class)* `Hash` — Ruby core key-value mapping" },
        .{ "Symbol", "*(class)* `Symbol` — Ruby core immutable identifier" },
        .{ "Regexp", "*(class)* `Regexp` — Ruby core regular expression" },
        .{ "Range", "*(class)* `Range` — Ruby core range object" },
        .{ "IO", "*(class)* `IO` — Ruby core I/O stream" },
        .{ "File", "*(class)* `File` — Ruby core file operations (inherits IO)" },
        .{ "Dir", "*(class)* `Dir` — Ruby core directory operations" },
        .{ "Proc", "*(class)* `Proc` — Ruby core callable block/lambda" },
        .{ "Method", "*(class)* `Method` — Ruby core bound method object" },
        .{ "Thread", "*(class)* `Thread` — Ruby core concurrent execution" },
        .{ "Mutex", "*(class)* `Mutex` — Ruby core mutual exclusion lock" },
        .{ "Fiber", "*(class)* `Fiber` — Ruby core lightweight concurrency" },
        .{ "Encoding", "*(class)* `Encoding` — Ruby core character encoding" },
        .{ "Comparable", "*(module)* `Comparable` — mixin for `<=>` based comparison" },
        .{ "Enumerable", "*(module)* `Enumerable` — mixin for collection traversal" },
        .{ "Kernel", "*(module)* `Kernel` — mixed into every Ruby object" },
        .{ "Process", "*(module)* `Process` — OS process management" },
        .{ "Math", "*(module)* `Math` — trigonometric and transcendental functions" },
        .{ "Errno", "*(module)* `Errno` — system error code constants" },
        .{ "Marshal", "*(module)* `Marshal` — Ruby object serialization" },
        .{ "ObjectSpace", "*(module)* `ObjectSpace` — Ruby object introspection" },
        .{ "GC", "*(module)* `GC` — garbage collector control" },
        .{ "ENV", "*(object)* `ENV` — environment variable accessor (Hash-like)" },
        .{ "STDIN", "*(constant)* `STDIN` — standard input stream" },
        .{ "STDOUT", "*(constant)* `STDOUT` — standard output stream" },
        .{ "STDERR", "*(constant)* `STDERR` — standard error stream" },
        .{ "ARGV", "*(constant)* `ARGV` — command-line arguments array" },
        .{ "TRUE", "*(constant)* `TRUE` — deprecated alias for `true`" },
        .{ "FALSE", "*(constant)* `FALSE` — deprecated alias for `false`" },
        .{ "NIL", "*(constant)* `NIL` — deprecated alias for `nil`" },
        .{ "Set", "*(class)* `Set` — unordered unique collection (require 'set')" },
        .{ "Struct", "*(class)* `Struct` — data class generator" },
        .{ "OpenStruct", "*(class)* `OpenStruct` — dynamic attribute object (require 'ostruct')" },
        .{ "BigDecimal", "*(class)* `BigDecimal` — arbitrary precision decimal (require 'bigdecimal')" },
        .{ "Pathname", "*(class)* `Pathname` — OO filesystem path (require 'pathname')" },
        .{ "URI", "*(module)* `URI` — URI parsing and manipulation (require 'uri')" },
        .{ "JSON", "*(module)* `JSON` — JSON encoding/decoding (require 'json')" },
        .{ "YAML", "*(module)* `YAML` — YAML parsing (require 'yaml')" },
        .{ "CSV", "*(class)* `CSV` — CSV reading/writing (require 'csv')" },
        .{ "Logger", "*(class)* `Logger` — simple logging (require 'logger')" },
        .{ "StringIO", "*(class)* `StringIO` — in-memory IO on strings (require 'stringio')" },
        .{ "Tempfile", "*(class)* `Tempfile` — temporary file with auto-cleanup (require 'tempfile')" },
        .{ "Socket", "*(class)* `Socket` — network socket (require 'socket')" },
        .{ "Net", "*(module)* `Net` — network protocol clients (require 'net/http')" },
        .{ "Digest", "*(module)* `Digest` — message digests (require 'digest')" },
        .{ "Base64", "*(module)* `Base64` — Base64 encoding (require 'base64')" },
        .{ "SecureRandom", "*(module)* `SecureRandom` — cryptographic random (require 'securerandom')" },
        .{ "Exception", "*(class)* `Exception` — base class for all exceptions" },
        .{ "StandardError", "*(class)* `StandardError` — base class for rescuable errors" },
        .{ "RuntimeError", "*(class)* `RuntimeError` — default error for `raise`" },
        .{ "TypeError", "*(class)* `TypeError` — type mismatch error" },
        .{ "ArgumentError", "*(class)* `ArgumentError` — wrong number/type of arguments" },
        .{ "NameError", "*(class)* `NameError` — undefined name reference" },
        .{ "NoMethodError", "*(class)* `NoMethodError` — undefined method call" },
        .{ "NotImplementedError", "*(class)* `NotImplementedError` — unimplemented method stub" },
        .{ "IOError", "*(class)* `IOError` — I/O operation failure" },
        .{ "Errno::ENOENT", "*(class)* `Errno::ENOENT` — file not found" },
        .{ "KeyError", "*(class)* `KeyError` — missing key in Hash/ENV" },
        .{ "IndexError", "*(class)* `IndexError` — index out of range" },
        .{ "StopIteration", "*(class)* `StopIteration` — iterator exhausted" },
        .{ "LoadError", "*(class)* `LoadError` — require/load failure" },
        .{ "SyntaxError", "*(class)* `SyntaxError` — parse error" },
        .{ "RegexpError", "*(class)* `RegexpError` — invalid regular expression" },
        .{ "ZeroDivisionError", "*(class)* `ZeroDivisionError` — division by zero" },
        .{ "SystemCallError", "*(class)* `SystemCallError` — OS-level error base class" },
        .{ "SignalException", "*(class)* `SignalException` — trapped OS signal" },
        .{ "Interrupt", "*(class)* `Interrupt` — Ctrl-C / SIGINT" },
        .{ "TrueClass", "*(class)* `TrueClass` — class of `true`" },
        .{ "FalseClass", "*(class)* `FalseClass` — class of `false`" },
        .{ "NilClass", "*(class)* `NilClass` — class of `nil`" },
        .{ "Numeric", "*(class)* `Numeric` — base class for numbers" },
        .{ "Complex", "*(class)* `Complex` — complex number" },
        .{ "Rational", "*(class)* `Rational` — exact fraction" },
        .{ "Object", "*(class)* `Object` — default superclass of all Ruby classes" },
        .{ "BasicObject", "*(class)* `BasicObject` — root of the class hierarchy" },
        .{ "Module", "*(class)* `Module` — base for classes and modules" },
        .{ "Class", "*(class)* `Class` — metaclass of all classes" },
    };
    inline for (entries) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return null;
}

fn resolveHoverReceiverType(self: *Server, path: []const u8, recv_name: []const u8, hover_line: u32) !?[]const u8 {
    const cursor_line: i64 = @intCast(hover_line + 1);
    const fstmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer fstmt.finalize();
    fstmt.bind_text(1, path);
    if (try fstmt.step()) {
        const fid = fstmt.column_int(0);
        // Check local_vars for the receiver (includes @ prefix for instance vars)
        const lv = try self.db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND line<=? AND type_hint IS NOT NULL ORDER BY line DESC LIMIT 1");
        defer lv.finalize();
        lv.bind_int(1, fid);
        lv.bind_text(2, recv_name);
        lv.bind_int(3, cursor_line);
        if (try lv.step()) {
            const t = lv.column_text(0);
            if (t.len > 0) return t;
        }
    }
    return null;
}

fn hoverLookupOnClass(self: *Server, msg: types.RequestMessage, method_name: []const u8, class_name: []const u8, hover_line: u32, wc16: u32, we16: u32) !?types.ResponseMessage {
    const stmt = try self.db.prepare(
        \\SELECT s.kind, s.line, s.return_type, s.doc, f.path, s.id, s.parent_name
        \\FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE s.name = ?1 AND (s.parent_name = ?2 OR (s.parent_name IS NULL AND s.file_id IN (
        \\  SELECT file_id FROM symbols WHERE kind IN ('class','module') AND name = ?2
        \\))) AND s.kind IN ('def','classdef')
        \\ORDER BY (s.parent_name = ?2) DESC, (s.doc IS NOT NULL) DESC
        \\LIMIT 1
    );
    defer stmt.finalize();
    stmt.bind_text(1, method_name);
    stmt.bind_text(2, class_name);
    if (!(try stmt.step())) return null;

    const kind_str = stmt.column_text(0);
    const sym_line = stmt.column_int(1);
    const return_type = stmt.column_text(2);
    const doc = stmt.column_text(3);
    const sym_path = stmt.column_text(4);
    const sym_id = stmt.column_int(5);
    const parent = stmt.column_text(6);
    const kind_label: []const u8 = if (std.mem.eql(u8, kind_str, "classdef")) "def self" else "def";

    var param_sig_buf = std.ArrayList(u8).empty;
    defer param_sig_buf.deinit(self.alloc);
    const ps = self.db.prepare(
        \\SELECT GROUP_CONCAT(
        \\  CASE p.kind WHEN 'keyword' THEN p.name||':' WHEN 'rest' THEN '*'||p.name
        \\  WHEN 'keyword_rest' THEN '**'||p.name WHEN 'block' THEN '&'||p.name
        \\  ELSE p.name END, ', ')
        \\FROM params p WHERE p.symbol_id=? ORDER BY p.position
    ) catch null;
    if (ps) |s| {
        defer s.finalize();
        s.bind_int(1, sym_id);
        if (s.step() catch false) {
            const sig = s.column_text(0);
            if (sig.len > 0) param_sig_buf.appendSlice(self.alloc, sig) catch {};
        }
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"*(");
    try writeEscapedJsonContent(w, kind_label);
    try w.writeAll(")* `");
    if (parent.len > 0) {
        try writeEscapedJsonContent(w, parent);
        if (std.mem.eql(u8, kind_str, "classdef")) try w.writeAll(".") else try w.writeAll("#");
    }
    try writeEscapedJsonContent(w, method_name);
    if (param_sig_buf.items.len > 0) {
        try w.writeAll("(");
        try writeEscapedJsonContent(w, param_sig_buf.items);
        try w.writeAll(")");
    }
    try w.writeByte('`');
    if (return_type.len > 0) {
        try w.writeAll(" \\u2192 ");
        try writeEscapedJsonContent(w, return_type);
    }
    try w.writeAll("\\n\\n\\u2192 ");
    try writeEscapedJsonContent(w, relPathFor(sym_path, self.root_path));
    try w.print(":{d}", .{sym_line});
    if (doc.len > 0) {
        try w.writeAll("\\n\\n");
        try writeEscapedJsonContent(w, doc);
    }
    try w.writeAll("\"}");
    try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ hover_line, wc16, hover_line, we16 });
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

fn writeClassMethodList(self: *Server, w: *std.Io.Writer, class_name: []const u8, kind: []const u8, label: []const u8) !void {
    const method_limit: i64 = 12;
    const count_stmt = self.db.prepare(
        \\SELECT COUNT(DISTINCT name) FROM symbols
        \\WHERE parent_name = ? AND kind = ?
        \\  AND (visibility IS NULL OR visibility != 'private')
    ) catch return;
    defer count_stmt.finalize();
    count_stmt.bind_text(1, class_name);
    count_stmt.bind_text(2, kind);
    var total: i64 = 0;
    if (count_stmt.step() catch false) total = count_stmt.column_int(0);
    if (total == 0) return;

    const list_stmt = self.db.prepare(
        \\SELECT DISTINCT name FROM symbols
        \\WHERE parent_name = ? AND kind = ?
        \\  AND (visibility IS NULL OR visibility != 'private')
        \\ORDER BY (doc IS NOT NULL) DESC, name
        \\LIMIT ?
    ) catch return;
    defer list_stmt.finalize();
    list_stmt.bind_text(1, class_name);
    list_stmt.bind_text(2, kind);
    list_stmt.bind_int(3, method_limit);

    try w.writeAll("\\n\\n**");
    try writeEscapedJsonContent(w, label);
    try w.writeAll(":** ");
    var first = true;
    var shown: i64 = 0;
    while (list_stmt.step() catch false) {
        const mname = list_stmt.column_text(0);
        if (mname.len == 0) continue;
        if (first) {
            try w.writeByte('`');
            first = false;
        } else {
            try w.writeAll("`, `");
        }
        try writeEscapedJsonContent(w, mname);
        shown += 1;
    }
    if (!first) try w.writeByte('`');
    if (total > shown) {
        try w.print(" _(+{d} more)_", .{total - shown});
    }
}

fn relPathFor(sym_path: []const u8, root_path: ?[]u8) []const u8 {
    const rp = root_path orelse return sym_path;
    if (!std.mem.startsWith(u8, sym_path, rp)) return sym_path;
    const after = sym_path[rp.len..];
    return if (after.len > 0 and after[0] == '/') after[1..] else after;
}

pub fn hoverLookup(self: *Server, msg: types.RequestMessage, name: []const u8, current_path: []const u8, hover_line: u32, wc16: u32, we16: u32) !?types.ResponseMessage {
    const stmt = try self.db.prepare(
        \\SELECT s.kind, s.line, s.return_type, s.doc, f.path, s.id, s.value_snippet, s.parent_name
        \\FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE s.name = ? OR (s.name LIKE '%::' || ? AND s.kind IN ('class','module','association','scope','validation','callback'))
        \\ORDER BY CASE WHEN f.path = ? THEN 0 ELSE 1 END, CASE WHEN s.name = ? THEN 0 ELSE 1 END, s.id
        \\LIMIT 1
    );
    defer stmt.finalize();
    stmt.bind_text(1, name);
    stmt.bind_text(2, name);
    stmt.bind_text(3, current_path);
    stmt.bind_text(4, name);

    if (!(try stmt.step())) return null;

    const kind_str = stmt.column_text(0);
    const sym_line = stmt.column_int(1);
    const return_type = stmt.column_text(2);
    const doc = stmt.column_text(3);
    const sym_path = stmt.column_text(4);
    const sym_id = stmt.column_int(5);
    const value_snippet = stmt.column_text(6);
    const parent_name = stmt.column_text(7);

    const kind_label: []const u8 = if (std.mem.eql(u8, kind_str, "classdef")) "def self" else if (std.mem.eql(u8, kind_str, "validation")) "validation" else if (std.mem.eql(u8, kind_str, "callback")) "callback" else kind_str;

    // Fetch parameter signature for def symbols
    var param_sig_buf = std.ArrayList(u8).empty;
    defer param_sig_buf.deinit(self.alloc);
    // Structured params for the **Parameters:** block (name, type, description, kind)
    const ParamDetail = struct { name: []u8, type_hint: []u8, description: []u8, kind: []u8 };
    var param_details = std.ArrayList(ParamDetail).empty;
    defer {
        for (param_details.items) |pd| {
            self.alloc.free(pd.name);
            self.alloc.free(pd.type_hint);
            self.alloc.free(pd.description);
            self.alloc.free(pd.kind);
        }
        param_details.deinit(self.alloc);
    }
    if (std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) {
        const ps = self.db.prepare(
            \\SELECT GROUP_CONCAT(
            \\  CASE p.kind
            \\    WHEN 'keyword' THEN p.name || ':' || IIF(p.type_hint IS NOT NULL AND (p.confidence IS NULL OR p.confidence >= 50), ' ' || p.type_hint, '')
            \\    WHEN 'rest' THEN '*' || p.name || IIF(p.type_hint IS NOT NULL AND (p.confidence IS NULL OR p.confidence >= 50), ': ' || p.type_hint, '')
            \\    WHEN 'keyword_rest' THEN '**' || p.name
            \\    WHEN 'block' THEN '&' || p.name
            \\    ELSE p.name || IIF(p.type_hint IS NOT NULL AND (p.confidence IS NULL OR p.confidence >= 50), ': ' || p.type_hint, '')
            \\  END, ', ')
            \\FROM params p WHERE p.symbol_id=? ORDER BY p.position
        ) catch null;
        if (ps) |s| {
            defer s.finalize();
            s.bind_int(1, sym_id);
            if (s.step() catch false) {
                const sig = s.column_text(0);
                if (sig.len > 0) param_sig_buf.appendSlice(self.alloc, sig) catch {}; // OOM: signature building
            }
        }
        // Fetch individual param details for the Parameters section
        const pd_stmt = self.db.prepare(
            \\SELECT p.name, COALESCE(p.type_hint,''), COALESCE(p.description,''), p.kind
            \\FROM params p WHERE p.symbol_id=? ORDER BY p.position
        ) catch null;
        if (pd_stmt) |pds| {
            defer pds.finalize();
            pds.bind_int(1, sym_id);
            while (pds.step() catch false) {
                const pd = ParamDetail{
                    .name = self.alloc.dupe(u8, pds.column_text(0)) catch continue,
                    .type_hint = self.alloc.dupe(u8, pds.column_text(1)) catch blk: {
                        self.alloc.free(self.alloc.dupe(u8, "") catch "");
                        break :blk self.alloc.dupe(u8, "") catch continue;
                    },
                    .description = self.alloc.dupe(u8, pds.column_text(2)) catch blk: {
                        break :blk self.alloc.dupe(u8, "") catch continue;
                    },
                    .kind = self.alloc.dupe(u8, pds.column_text(3)) catch blk: {
                        break :blk self.alloc.dupe(u8, "") catch continue;
                    },
                };
                param_details.append(self.alloc, pd) catch {
                    self.alloc.free(pd.name);
                    self.alloc.free(pd.type_hint);
                    self.alloc.free(pd.description);
                    self.alloc.free(pd.kind);
                };
            }
        }
    }

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"*(");
    try writeEscapedJsonContent(w, kind_label);
    try w.writeAll(")* `");
    if (std.mem.eql(u8, kind_str, "constant") and parent_name.len > 0) {
        try writeEscapedJsonContent(w, parent_name);
        try w.writeAll("::");
    }
    try writeEscapedJsonContent(w, name);
    if (param_sig_buf.items.len > 0) {
        try w.writeAll("(");
        try writeEscapedJsonContent(w, param_sig_buf.items);
        try w.writeAll(")");
    }
    try w.writeByte('`');
    if ((std.mem.eql(u8, kind_str, "def") or std.mem.eql(u8, kind_str, "classdef")) and return_type.len > 0) {
        try w.writeAll(" \\u2192 ");
        try writeEscapedJsonContent(w, return_type);
        if (self.isNilableMethod(name)) {
            try w.writeAll(" | nil");
        }
    }
    if (std.mem.eql(u8, kind_str, "constant") and value_snippet.len > 0) {
        try w.writeAll(" = `");
        try writeEscapedJsonContent(w, value_snippet);
        try w.writeByte('`');
    }
    if (std.mem.eql(u8, kind_str, "association") and value_snippet.len > 0) {
        try w.writeAll("\\n\\n```ruby\\n");
        try writeEscapedJsonContent(w, value_snippet);
        try w.writeAll("\\n```");
    }
    try w.writeAll("\\n\\n\\u2192 ");
    try writeEscapedJsonContent(w, relPathFor(sym_path, self.root_path));
    try w.print(":{d}", .{sym_line});
    if (doc.len > 0) {
        try w.writeAll("\\n\\n");
        try writeEscapedJsonContent(w, doc);
    }
    // **Parameters:** section — shown when ≥1 param has a type or description
    if (param_details.items.len >= 1) {
        var has_detail = false;
        for (param_details.items) |pd| {
            if (pd.type_hint.len > 0 or pd.description.len > 0) {
                has_detail = true;
                break;
            }
        }
        if (has_detail) {
            try w.writeAll("\\n\\n**Parameters:**");
            for (param_details.items) |pd| {
                try w.writeAll("\\n- `");
                const prefix: []const u8 = if (std.mem.eql(u8, pd.kind, "rest")) "*" else if (std.mem.eql(u8, pd.kind, "keyword_rest")) "**" else if (std.mem.eql(u8, pd.kind, "block")) "&" else "";
                try writeEscapedJsonContent(w, prefix);
                try writeEscapedJsonContent(w, pd.name);
                try w.writeByte('`');
                if (pd.type_hint.len > 0) {
                    try w.writeAll(" _(");
                    try writeEscapedJsonContent(w, pd.type_hint);
                    try w.writeAll(")_");
                }
                if (pd.description.len > 0) {
                    try w.writeAll(" — ");
                    try writeEscapedJsonContent(w, pd.description);
                }
            }
        }
    }
    if (std.mem.eql(u8, kind_str, "class") or std.mem.eql(u8, kind_str, "module")) {
        if (parent_name.len > 0 and !std.mem.eql(u8, parent_name, "Object")) {
            try w.writeAll("\\n\\n**Inherits:** `");
            try writeEscapedJsonContent(w, parent_name);
            try w.writeByte('`');
        }
        const mx_stmt = self.db.prepare("SELECT module_name FROM mixins WHERE class_id = ? AND kind IN ('include','prepend') ORDER BY rowid") catch null;
        if (mx_stmt) |ms| {
            defer ms.finalize();
            ms.bind_int(1, sym_id);
            var first_mx = true;
            while (ms.step() catch false) {
                const mod = ms.column_text(0);
                if (first_mx) {
                    try w.writeAll("\\n\\n**Includes:** `");
                    first_mx = false;
                } else {
                    try w.writeAll("`, `");
                }
                try writeEscapedJsonContent(w, mod);
            }
            if (!first_mx) try w.writeByte('`');
        }
        const ext_stmt = self.db.prepare("SELECT module_name FROM mixins WHERE class_id = ? AND kind = 'extend' ORDER BY rowid") catch null;
        if (ext_stmt) |es| {
            defer es.finalize();
            es.bind_int(1, sym_id);
            var first_ext = true;
            while (es.step() catch false) {
                const mod = es.column_text(0);
                if (first_ext) {
                    try w.writeAll("\\n\\n**Extends:** `");
                    first_ext = false;
                } else {
                    try w.writeAll("`, `");
                }
                try writeEscapedJsonContent(w, mod);
            }
            if (!first_ext) try w.writeByte('`');
        }
        try writeClassMethodList(self, w, name, "classdef", "Class methods");
        try writeClassMethodList(self, w, name, "def", "Instance methods");
    }
    try w.writeAll("\"}");
    try w.print(",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ hover_line, wc16, hover_line, we16 });

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn hoverI18n(self: *Server, msg: types.RequestMessage, source: []const u8, offset: usize, hover_line: u32, wc16: u32, we16: u32) !?types.ResponseMessage {
    var key_start = offset;
    while (key_start > 0 and source[key_start - 1] != '"' and source[key_start - 1] != '\'') {
        key_start -= 1;
    }
    if (key_start > 0) key_start -= 1;
    if (key_start >= source.len) return null;
    key_start += 1;
    var key_end = offset;
    while (key_end < source.len and source[key_end] != '"' and source[key_end] != '\'') {
        key_end += 1;
    }
    const full_key = source[key_start..key_end];

    const stmt = self.db.prepare(
        \\SELECT value, locale FROM i18n_keys WHERE key = ?
        \\ORDER BY locale LIMIT 10
    ) catch return null;
    defer stmt.finalize();
    stmt.bind_text(1, full_key);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":");

    var found_any = false;
    try w.writeAll("\"**");
    try writeEscapedJsonContent(w, full_key);
    try w.writeAll("**");
    try w.writeAll("\\n\\n");

    while (try stmt.step()) {
        const value = stmt.column_text(0);
        const locale = stmt.column_text(1);
        found_any = true;
        try w.writeAll("_");
        try writeEscapedJsonContent(w, locale);
        try w.writeAll("_: ");
        try writeEscapedJsonContent(w, value);
        try w.writeAll("\\n\\n");
    }

    if (!found_any) {
        try w.writeAll("_(no translations found)_");
    }

    try w.writeAll("\"");
    try w.print("}},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{ hover_line, wc16, hover_line, we16 });

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}
