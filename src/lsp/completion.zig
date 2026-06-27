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
pub const writeInsertTextSnippet = c_common.writeInsertTextSnippet;

const c_dot = @import("completion_dot.zig");
const completeDot = c_dot.completeDot;
const c_sym = @import("completion_symbols.zig");
const completeGeneral = c_sym.completeGeneral;
const completeAllSymbols = c_sym.completeAllSymbols;
const completeArgContext = c_sym.completeArgContext;
const c_special = @import("completion_special.zig");
const RequireKind = c_special.RequireKind;
const detectRequireContext = c_special.detectRequireContext;
const detectEnvContext = c_special.detectEnvContext;
const completeEnvKeys = c_special.completeEnvKeys;
const completeRequirePath = c_special.completeRequirePath;
const completeNamespace = c_special.completeNamespace;
const completeInstanceVars = c_special.completeInstanceVars;
const completeGlobalVars = c_special.completeGlobalVars;
const completeI18n = c_special.completeI18n;
const completeRouteHelpers = c_special.completeRouteHelpers;

pub fn handleCompletion(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    // Background flush worker drains dirty URIs; query path stays read-only.
    // Lockless read on read_db when available; falls back to db_mutex otherwise.
    const rtx = self.beginRead();
    defer rtx.end();
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

    if (std.mem.endsWith(u8, path, ".erb") and !erb_mapping.isErbRubyContext(source, offset)) {
        var aw_erb = std.Io.Writer.Allocating.init(self.alloc);
        const ew = &aw_erb.writer;
        try ew.writeAll("{\"isIncomplete\":false,\"items\":[");
        var erb_first = true;
        for (erb_mapping.RAILS_VIEW_HELPERS) |helper| {
            if (!erb_first) try ew.writeByte(',');
            erb_first = false;
            try ew.writeAll("{\"label\":");
            try writeEscapedJson(ew, helper.name);
            try ew.writeAll(",\"kind\":3,\"detail\":");
            try writeEscapedJson(ew, helper.detail);
            try ew.writeAll(",\"insertTextFormat\":2,\"insertText\":");
            try writeEscapedJson(ew, helper.snippet);
            try ew.writeByte('}');
        }
        try ew.writeAll("]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_erb.toOwnedSlice(), .@"error" = null };
    }

    const word = extractWord(source, offset);

    if (detectRequireContext(source, offset) != null)
        return try completeRequirePath(self, msg, path, source, offset);
    if (Server.detectI18nContext(source, offset))
        return try completeI18n(self, msg, source, offset);
    if (detectEnvContext(source, offset)) |env_prefix|
        return try completeEnvKeys(self, msg, env_prefix);
    if (isInStringOrComment(source, offset)) {
        var aw_empty = std.Io.Writer.Allocating.init(self.alloc);
        try aw_empty.writer.writeAll("{\"isIncomplete\":false,\"items\":[]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_empty.toOwnedSlice(), .@"error" = null };
    }
    var is_receiver_context = false;
    if (word.len == 0 and offset > 0) {
        var p: usize = offset - 1;
        while (p > 0 and (source[p] == ' ' or source[p] == '\t' or source[p] == '\n' or source[p] == '\r')) : (p -= 1) {}
        if (source[p] == '.') {
            is_receiver_context = true;
            if (try completeDot(self, msg, path, source, line, character, p + 1, word)) |r| return r;
        } else if (p >= 1 and source[p] == ':' and source[p - 1] == ':') {
            is_receiver_context = true;
            if (try completeNamespace(self, msg, source, p + 1, word)) |r| return r;
        }
    }
    if (word.len > 0) {
        const word_start = @intFromPtr(word.ptr) - @intFromPtr(source.ptr);
        if (word_start > 0) {
            var p: usize = word_start - 1;
            while (p > 0 and (source[p] == ' ' or source[p] == '\t' or source[p] == '\n' or source[p] == '\r')) : (p -= 1) {}
            if (source[p] == '.') {
                is_receiver_context = true;
                if (try completeDot(self, msg, path, source, line, character, p + 1, word)) |r| return r;
            } else if (p >= 1 and source[p] == ':' and source[p - 1] == ':') {
                is_receiver_context = true;
                if (try completeNamespace(self, msg, source, p + 1, word)) |r| return r;
            }
        }
    }
    if (is_receiver_context) {
        var aw_empty = std.Io.Writer.Allocating.init(self.alloc);
        try aw_empty.writer.writeAll("{\"isIncomplete\":true,\"items\":[]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_empty.toOwnedSlice(), .@"error" = null };
    }
    if (word.len > 0 and word[0] == '$')
        return try completeGlobalVars(self, msg, word);
    if (indexing_in_progress) {
        var aw_busy = std.Io.Writer.Allocating.init(self.alloc);
        try aw_busy.writer.writeAll("{\"isIncomplete\":true,\"items\":[]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw_busy.toOwnedSlice(), .@"error" = null };
    }
    if (word.len == 0 and offset > 0 and (source[offset - 1] == '(' or source[offset - 1] == ',' or source[offset - 1] == '=' or source[offset - 1] == ' '))
        return try completeArgContext(self, msg, path, source, line, offset);
    if (word.len == 0)
        return try completeAllSymbols(self, msg);
    if (word.len > 0 and word[0] == '@')
        return try completeInstanceVars(self, msg, path, source, line, word);
    if (word.len > 0 and (std.mem.endsWith(u8, word, "_path") or std.mem.endsWith(u8, word, "_url") or std.mem.endsWith(u8, word, "_p") or std.mem.endsWith(u8, word, "_u")))
        return try completeRouteHelpers(self, msg, word);
    return try completeGeneral(self, msg, path, source, line, character, word, offset);
}

pub fn handleCompletionItemResolve(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    const rtx = self.beginRead();
    defer rtx.end();
    const params = msg.params orelse return emptyResult(msg);
    const item_obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };

    const data_val = item_obj.get("data") orelse {
        const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = raw,
            .@"error" = null,
        };
    };
    const data_obj = switch (data_val) {
        .object => |o| o,
        else => {
            const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = raw,
                .@"error" = null,
            };
        },
    };
    const name_val = data_obj.get("name") orelse {
        const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = raw,
            .@"error" = null,
        };
    };
    const name = switch (name_val) {
        .string => |s| s,
        else => {
            const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = raw,
                .@"error" = null,
            };
        },
    };

    const def_stmt = try self.cachedStmt("SELECT doc, return_type FROM symbols WHERE name = ? AND kind = 'def' LIMIT 1");
    defer def_stmt.reset();
    def_stmt.bind_text(1, name);
    if (!(try def_stmt.step())) {
        const raw = std.json.Stringify.valueAlloc(self.alloc, params, .{}) catch null;
        return types.ResponseMessage{
            .id = msg.id,
            .result = null,
            .raw_result = raw,
            .@"error" = null,
        };
    }

    const doc = def_stmt.column_text(0);
    const return_type = def_stmt.column_text(1);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('{');

    var first_field = true;
    var iter = item_obj.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "data")) continue;
        if (!first_field) try w.writeByte(',');
        first_field = false;
        try writeEscapedJson(w, entry.key_ptr.*);
        try w.writeByte(':');
        const val_str = std.json.Stringify.valueAlloc(self.alloc, entry.value_ptr.*, .{}) catch "null";
        defer self.alloc.free(val_str);
        try w.writeAll(val_str);
    }

    if (return_type.len > 0) {
        if (!first_field) try w.writeByte(',');
        first_field = false;
        try w.writeAll("\"detail\":\"");
        try w.writeAll("\u{2192} ");
        try writeEscapedJsonContent(w, return_type);
        try w.writeByte('"');
    }

    if (doc.len > 0) {
        if (!first_field) try w.writeByte(',');
        first_field = false;
        try w.writeAll("\"documentation\":{\"kind\":\"markdown\",\"value\":\"");
        try writeEscapedJsonContent(w, doc);
        try w.writeAll("\"}");
    }

    try w.writeByte('}');

    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

const inline_completion = @import("inline_completion.zig");
pub const handleInlineCompletion = inline_completion.handleInlineCompletion;
