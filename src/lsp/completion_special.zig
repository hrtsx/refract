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

const c_common = @import("completion_common.zig");
const writeInsertTextSnippet = c_common.writeInsertTextSnippet;
const addStdlibCompletions = c_common.addStdlibCompletions;

pub const RequireKind = enum { require, require_relative };

pub fn detectRequireContext(source: []const u8, offset: usize) ?RequireKind {
    if (offset == 0) return null;
    var i = offset;
    // Skip back over any partial string
    while (i > 0 and source[i - 1] != '\'' and source[i - 1] != '"') i -= 1;
    if (i == 0) return null;
    i -= 1; // skip the opening quote
    // Skip whitespace
    while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t')) i -= 1;
    // Check for 'require_relative' (16 chars) or 'require' (7 chars)
    if (i >= 16 and std.mem.eql(u8, source[i - 16 .. i], "require_relative")) return .require_relative;
    if (i >= 7 and std.mem.eql(u8, source[i - 7 .. i], "require")) return .require;
    return null;
}

pub fn detectEnvContext(source: []const u8, offset: usize) ?[]const u8 {
    if (offset < 5) return null;
    // Walk back from cursor to find the opening quote
    var i = offset;
    while (i > 0 and source[i - 1] != '\'' and source[i - 1] != '"' and source[i - 1] != '[') i -= 1;
    if (i == 0) return null;
    const prefix_start = i;
    // At quote or bracket — if at quote, skip it and look for [
    if (source[i - 1] == '\'' or source[i - 1] == '"') {
        i -= 1;
        if (i == 0 or source[i - 1] != '[') return null;
    } else if (source[i - 1] != '[') return null;
    // Now at [, check for ENV before it
    i -= 1;
    if (i < 3) return null;
    if (!std.mem.eql(u8, source[i - 3 .. i], "ENV")) return null;
    // Make sure ENV isn't part of a larger identifier
    if (i > 3 and isRubyIdent(source[i - 4])) return null;
    return source[prefix_start..offset];
}

pub fn completeEnvKeys(self: *Server, msg: types.RequestMessage, prefix: []const u8) !types.ResponseMessage {
    // Rebuild cache on first call or after any file save.
    if (self.env_keys_dirty.load(.acquire)) {
        self.env_keys_mu.lockUncancelable(std.Options.debug_io);
        defer self.env_keys_mu.unlock(std.Options.debug_io);
        // Double-checked: another thread may have rebuilt between the load and lock.
        if (self.env_keys_dirty.load(.monotonic)) {
            // Free existing cache entries.
            for (self.env_keys_cache.items) |k| self.alloc.free(k);
            self.env_keys_cache.clearRetainingCapacity();

            var seen = std.StringHashMap(void).init(self.alloc);
            defer {
                var it = seen.keyIterator();
                while (it.next()) |k| self.alloc.free(k.*);
                seen.deinit();
            }

            // Bound the workspace file read so a large repo can't turn one
            // keystroke into an O(all-files) stall on the query path. When the
            // cap trips we mark the key set incomplete so the client refines.
            self.env_keys_truncated = false;
            const max_files: usize = 2000;
            const max_bytes: usize = 48 * 1024 * 1024;
            var files_scanned: usize = 0;
            var bytes_scanned: usize = 0;

            const file_stmt = self.cachedStmt("SELECT path FROM files WHERE is_gem = 0") catch null;
            if (file_stmt) |fs| {
                defer fs.reset();
                while (fs.step() catch false) {
                    if (files_scanned >= max_files or bytes_scanned >= max_bytes) {
                        self.env_keys_truncated = true;
                        break;
                    }
                    files_scanned += 1;
                    const fpath = fs.column_text(0);
                    const fsrc = std.Io.Dir.cwd().readFileAllocOptions(std.Options.debug_io, fpath, self.alloc, std.Io.Limit.limited(512 * 1024), .@"1", 0) catch continue;
                    defer self.alloc.free(fsrc);
                    bytes_scanned += fsrc.len;

                    var pos: usize = 0;
                    while (pos + 4 < fsrc.len) {
                        const idx = std.mem.indexOf(u8, fsrc[pos..], "ENV") orelse break;
                        pos += idx + 3;
                        if (pos >= fsrc.len) break;
                        var key_start: usize = 0;
                        var key_end: usize = 0;
                        if (fsrc[pos] == '[' and pos + 2 < fsrc.len and (fsrc[pos + 1] == '\'' or fsrc[pos + 1] == '"')) {
                            const q = fsrc[pos + 1];
                            key_start = pos + 2;
                            key_end = key_start;
                            while (key_end < fsrc.len and fsrc[key_end] != q) key_end += 1;
                        } else if (pos + 8 < fsrc.len and std.mem.startsWith(u8, fsrc[pos..], ".fetch(")) {
                            const fpos = pos + 7;
                            if (fpos < fsrc.len and (fsrc[fpos] == '\'' or fsrc[fpos] == '"')) {
                                const q = fsrc[fpos];
                                key_start = fpos + 1;
                                key_end = key_start;
                                while (key_end < fsrc.len and fsrc[key_end] != q) key_end += 1;
                            } else continue;
                        } else continue;

                        if (key_end > key_start and key_end - key_start < 128) {
                            const key = fsrc[key_start..key_end];
                            if (!seen.contains(key)) {
                                const owned = self.alloc.dupe(u8, key) catch continue;
                                seen.put(owned, {}) catch {
                                    self.alloc.free(owned);
                                    continue;
                                };
                                const cache_key = self.alloc.dupe(u8, key) catch continue;
                                self.env_keys_cache.append(self.alloc, cache_key) catch {
                                    self.alloc.free(cache_key);
                                };
                            }
                        }
                    }
                }
            }
            self.env_keys_dirty.store(false, .release);
        }
    }

    // Emit completions from cache, filtered by prefix.
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    self.env_keys_mu.lockUncancelable(std.Options.debug_io);
    defer self.env_keys_mu.unlock(std.Options.debug_io);
    if (self.env_keys_truncated)
        try w.writeAll("{\"isIncomplete\":true,\"items\":[")
    else
        try w.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first = true;
    var count: u32 = 0;
    for (self.env_keys_cache.items) |key| {
        if (prefix.len > 0 and !std.mem.startsWith(u8, key, prefix)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"label\":");
        try writeEscapedJson(w, key);
        try w.writeAll(",\"kind\":6}");
        count += 1;
        if (count >= 100) break;
    }
    try w.writeAll("]}");
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn completeRequirePath(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, offset: usize) !types.ResponseMessage {
    const req_kind = detectRequireContext(source, offset).?;
    const prefix_start = blk: {
        var idx = offset;
        while (idx > 0 and source[idx - 1] != '\'' and source[idx - 1] != '"') idx -= 1;
        break :blk idx;
    };
    const prefix = source[prefix_start..offset];
    var aw_req = std.Io.Writer.Allocating.init(self.alloc);
    const wr = &aw_req.writer;
    try wr.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first_req = true;
    if (req_kind == .require) {
        const stdlib = [_][]const u8{
            "json",      "set",          "date",      "pathname", "fileutils",        "ostruct",
            "digest",    "base64",       "uri",       "net/http", "open-uri",         "tempfile",
            "stringio",  "securerandom", "yaml",      "csv",      "optparse",         "logger",
            "singleton", "forwardable",  "delegate",  "observer", "thread",           "mutex_m",
            "monitor",   "timeout",      "benchmark", "pp",       "pstore",           "dbm",
            "socket",    "resolv",       "zlib",      "rake",     "minitest/autorun", "test/unit",
        };
        for (stdlib) |lib| {
            if (prefix.len == 0 or std.mem.startsWith(u8, lib, prefix)) {
                if (!first_req) try wr.writeByte(',');
                first_req = false;
                try wr.writeAll("{\"label\":");
                try writeEscapedJson(wr, lib);
                try wr.writeAll(",\"kind\":17}");
            }
        }
    }
    if (req_kind == .require_relative) {
        const dir_path = std.fs.path.dirname(path) orelse ".";
        var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dir_path, .{ .iterate = true }) catch {
            try wr.writeAll("]}");
            return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_req.toOwnedSlice(), .@"error" = null };
        };
        defer dir.close(std.Options.debug_io);
        var it = dir.iterate();
        while (it.next(std.Options.debug_io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".rb")) continue;
            const stem = entry.name[0 .. entry.name.len - 3];
            const rel = try std.fmt.allocPrint(self.alloc, "./{s}", .{stem});
            defer self.alloc.free(rel);
            if (prefix.len == 0 or std.mem.startsWith(u8, rel, prefix)) {
                if (!first_req) try wr.writeByte(',');
                first_req = false;
                try wr.writeAll("{\"label\":");
                try writeEscapedJson(wr, rel);
                try wr.writeAll(",\"kind\":17}");
            }
        }
    }
    try wr.writeAll("]}");
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_req.toOwnedSlice(), .@"error" = null };
}

pub fn completeNamespace(self: *Server, msg: types.RequestMessage, source: []const u8, offset: usize, word: []const u8) !?types.ResponseMessage {
    _ = word;
    var ns_offset = if (offset >= 3) offset - 3 else 0;
    while (ns_offset > 0 and (source[ns_offset] == ' ' or source[ns_offset] == '\t')) : (ns_offset -= 1) {}
    const ns_word = extractWord(source, ns_offset);
    if (ns_word.len == 0) return null;
    const ns_stmt = try self.cachedStmt(
        \\SELECT name, kind
        \\FROM symbols
        \\WHERE parent_name = ?
        \\  AND kind IN ('classdef', 'moduledef', 'constant', 'def', 'class', 'module')
        \\ORDER BY name LIMIT 100
    );
    defer ns_stmt.reset();
    ns_stmt.bind_text(1, ns_word);
    var aw_ns = std.Io.Writer.Allocating.init(self.alloc);
    const wns = &aw_ns.writer;
    try wns.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first_ns = true;
    while (try ns_stmt.step()) {
        if (!first_ns) try wns.writeByte(',');
        first_ns = false;
        const cname = ns_stmt.column_text(0);
        const ckind_str = ns_stmt.column_text(1);
        const ckind_num: u8 = if (std.mem.eql(u8, ckind_str, "classdef") or std.mem.eql(u8, ckind_str, "class")) 7 else if (std.mem.eql(u8, ckind_str, "moduledef") or std.mem.eql(u8, ckind_str, "module")) 9 else if (std.mem.eql(u8, ckind_str, "constant")) 21 else 3;
        try wns.writeAll("{\"label\":");
        try writeEscapedJson(wns, cname);
        try wns.print(",\"kind\":{d}", .{ckind_num});
        try wns.writeByte('}');
    }
    try wns.writeAll("]}");
    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw_ns.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn completeInstanceVars(self: *Server, msg: types.RequestMessage, path: []const u8, source: []const u8, line: u32, word: []const u8) !types.ResponseMessage {
    _ = source;
    const ivar_pattern = try buildQueryPattern(self.alloc, word);
    defer self.alloc.free(ivar_pattern);
    const ifc_stmt = try self.cachedStmt("SELECT id FROM files WHERE path = ?");
    defer ifc_stmt.reset();
    ifc_stmt.bind_text(1, path);
    var aw_iv = std.Io.Writer.Allocating.init(self.alloc);
    const wi = &aw_iv.writer;
    try wi.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first_iv = true;
    if (try ifc_stmt.step()) {
        const fid = ifc_stmt.column_int(0);
        const cls_stmt = self.cachedStmt("SELECT id FROM symbols WHERE file_id=? AND line<=? AND (kind='class' OR kind='module') ORDER BY line DESC LIMIT 1") catch null;
        const class_id: i64 = blk: {
            if (cls_stmt) |cs| {
                defer cs.reset();
                cs.bind_int(1, fid);
                cs.bind_int(2, @intCast(line + 1));
                if (cs.step() catch false) break :blk cs.column_int(0);
            }
            break :blk 0;
        };
        const iv_stmt = try self.cachedStmt("SELECT DISTINCT name, type_hint FROM local_vars WHERE file_id=? AND (class_id=? OR class_id IS NULL) AND name LIKE ? ESCAPE '\\'");
        defer iv_stmt.reset();
        iv_stmt.bind_int(1, fid);
        iv_stmt.bind_int(2, class_id);
        iv_stmt.bind_text(3, ivar_pattern);
        while (try iv_stmt.step()) {
            const iv_name = iv_stmt.column_text(0);
            const iv_type = iv_stmt.column_text(1);
            if (!first_iv) try wi.writeByte(',');
            first_iv = false;
            try wi.writeAll("{\"label\":");
            try writeEscapedJson(wi, iv_name);
            try wi.writeAll(",\"kind\":5");
            if (iv_type.len > 0) {
                try wi.writeAll(",\"detail\":\"");
                try writeEscapedJsonContent(wi, iv_type);
                try wi.writeByte('"');
            }
            try wi.writeAll(",\"sortText\":\"2_");
            try writeEscapedJsonContent(wi, iv_name);
            try wi.writeByte('"');
            try wi.writeAll(",\"filterText\":\"");
            try writeEscapedJsonContent(wi, iv_name);
            try wi.writeByte('"');
            try wi.writeByte('}');
        }
    }
    try wi.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw_iv.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn completeGlobalVars(self: *Server, msg: types.RequestMessage, word: []const u8) !types.ResponseMessage {
    const gv_pat = try buildPrefixPattern(self.alloc, word);
    defer self.alloc.free(gv_pat);
    const gv_stmt = try self.cachedStmt(
        \\SELECT DISTINCT name FROM local_vars
        \\WHERE name LIKE ? ESCAPE '\'
        \\ORDER BY name LIMIT 200
    );
    defer gv_stmt.reset();
    gv_stmt.bind_text(1, gv_pat);
    var aw_gv = std.Io.Writer.Allocating.init(self.alloc);
    const wg = &aw_gv.writer;
    try wg.writeAll("{\"isIncomplete\":false,\"items\":[");
    var gv_first = true;
    var gv_seen_arena = std.heap.ArenaAllocator.init(self.alloc);
    defer gv_seen_arena.deinit();
    var gv_seen = std.StringHashMap(void).init(gv_seen_arena.allocator());
    while (try gv_stmt.step()) {
        const gv_name = gv_stmt.column_text(0);
        if (gv_seen.contains(gv_name)) continue;
        gv_seen.put(try gv_seen_arena.allocator().dupe(u8, gv_name), {}) catch S.logOomOnce("completion.gv_seen");
        if (!gv_first) try wg.writeByte(',');
        gv_first = false;
        try wg.writeAll("{\"label\":");
        try writeEscapedJson(wg, gv_name);
        try wg.writeAll(",\"kind\":6,\"sortText\":\"1_");
        try writeEscapedJsonContent(wg, gv_name);
        try wg.writeAll("\",\"filterText\":");
        try writeEscapedJson(wg, gv_name);
        try wg.writeByte('}');
    }
    const ruby_globals = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "$stdout", .doc = "Standard output stream." },
        .{ .name = "$stderr", .doc = "Standard error stream." },
        .{ .name = "$stdin", .doc = "Standard input stream." },
        .{ .name = "$PROGRAM_NAME", .doc = "Current script name (same as $0)." },
        .{ .name = "$0", .doc = "Current script name." },
        .{ .name = "$LOAD_PATH", .doc = "Load path array (same as $:)." },
        .{ .name = "$:", .doc = "Load path array." },
        .{ .name = "$LOADED_FEATURES", .doc = "Loaded files array (same as $\")." },
        .{ .name = "$VERBOSE", .doc = "Verbose mode flag." },
        .{ .name = "$DEBUG", .doc = "Debug mode flag." },
        .{ .name = "$?", .doc = "Exit status of last child process." },
        .{ .name = "$~", .doc = "MatchData from last match." },
        .{ .name = "$&", .doc = "String matched by last regex." },
        .{ .name = "$1", .doc = "First capture group of last match." },
        .{ .name = "$2", .doc = "Second capture group of last match." },
        .{ .name = "$3", .doc = "Third capture group of last match." },
    };
    for (ruby_globals) |rg| {
        if (!std.mem.startsWith(u8, rg.name, word)) continue;
        if (gv_seen.contains(rg.name)) continue;
        if (!gv_first) try wg.writeByte(',');
        gv_first = false;
        try wg.writeAll("{\"label\":");
        try writeEscapedJson(wg, rg.name);
        try wg.writeAll(",\"kind\":6,\"detail\":\"(built-in)\",\"documentation\":{\"kind\":\"plaintext\",\"value\":");
        try writeEscapedJson(wg, rg.doc);
        try wg.writeAll("},\"sortText\":\"9_");
        try writeEscapedJsonContent(wg, rg.name);
        try wg.writeAll("\",\"filterText\":");
        try writeEscapedJson(wg, rg.name);
        try wg.writeByte('}');
    }
    try wg.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw_gv.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn completeI18n(self: *Server, msg: types.RequestMessage, source: []const u8, offset: usize) !types.ResponseMessage {
    var key_start = offset;
    while (key_start > 0 and source[key_start - 1] != '"' and source[key_start - 1] != '\'') {
        key_start -= 1;
    }
    if (key_start > 0) key_start -= 1;
    if (key_start >= source.len) return emptyResult(msg).?;
    key_start += 1;
    const partial_key = source[key_start..offset];

    const i18n_pattern = try buildPrefixPattern(self.alloc, partial_key);
    defer self.alloc.free(i18n_pattern);

    const stmt = self.cachedStmt(
        \\SELECT DISTINCT key, value FROM i18n_keys
        \\WHERE key LIKE ? ESCAPE '\'
        \\ORDER BY key LIMIT 50
    ) catch return emptyResult(msg).?;
    defer stmt.reset();
    stmt.bind_text(1, i18n_pattern);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first = true;
    while (try stmt.step()) {
        const key = stmt.column_text(0);
        const value = stmt.column_text(1);
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"label\":");
        try writeEscapedJson(w, key);
        try w.writeAll(",\"kind\":12,\"detail\":");
        try writeEscapedJson(w, value);
        try w.writeByte('}');
    }
    try w.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn completeRouteHelpers(self: *Server, msg: types.RequestMessage, word: []const u8) !types.ResponseMessage {
    if (word.len < 2) return emptyResult(msg).?;

    const route_pattern = try buildPrefixPattern(self.alloc, word);
    defer self.alloc.free(route_pattern);

    const stmt = self.cachedStmt(
        \\SELECT helper_name, http_method, path_pattern FROM routes
        \\WHERE helper_name LIKE ? ESCAPE '\'
        \\ORDER BY helper_name LIMIT 50
    ) catch return emptyResult(msg).?;
    defer stmt.reset();
    stmt.bind_text(1, route_pattern);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"isIncomplete\":false,\"items\":[");
    var first = true;
    while (try stmt.step()) {
        const helper_name = stmt.column_text(0);
        const http_method = stmt.column_text(1);
        const path_pattern = stmt.column_text(2);

        if (!first) try w.writeByte(',');
        first = false;

        try w.writeAll("{\"label\":");
        try writeEscapedJson(w, helper_name);
        try w.writeAll(",\"kind\":3,\"detail\":");
        try w.writeByte('"');
        try writeEscapedJsonContent(w, http_method);
        try w.writeAll(" ");
        try writeEscapedJsonContent(w, path_pattern);
        try w.writeAll("\",\"sortText\":\"1_");
        try writeEscapedJsonContent(w, helper_name);
        try w.writeByte('}');
    }
    try w.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}
