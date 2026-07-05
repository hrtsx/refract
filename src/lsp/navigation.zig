const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const erb_mapping = @import("erb_mapping.zig");
const editing = @import("editing.zig");
const hot_index_mod = @import("hot_index.zig");
const literal_receiver = @import("literal_receiver.zig");
const type_resolver = @import("type_resolver.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractParamsObject = S.extractParamsObject;
const extractPosition = S.extractPosition;
const uriToPath = S.uriToPath;
const emptyResult = S.emptyResult;
const writeEscapedJsonContent = S.writeEscapedJsonContent;
const writeEscapedJson = S.writeEscapedJson;
const writePathAsUri = S.writePathAsUri;
const getLineSlice = S.getLineSlice;
const extractWord = S.extractWord;
const extractQualifiedName = S.extractQualifiedName;
const extractBaseClass = S.extractBaseClass;
const utf8ColToUtf16 = S.utf8ColToUtf16;
const isInStringOrComment = S.isInStringOrComment;
const frcGet = S.frcGet;
const resolveRequireTarget = S.resolveRequireTarget;
const pathToUri = S.pathToUri;
const isRubyIdent = S.isRubyIdent;
const empty_json_array = S.empty_json_array;

const nav_symbols = @import("navigation_symbols.zig");
const writeLoc = nav_symbols.writeLoc;
const DefOrigin = nav_symbols.DefOrigin;
const emitOneDef = nav_symbols.emitOneDef;
const emitDefinitionOnClass = nav_symbols.emitDefinitionOnClass;
const tryEmitFromHotIndex = nav_symbols.tryEmitFromHotIndex;
const queryAndEmitDefinitions = nav_symbols.queryAndEmitDefinitions;

const navigation_definition = @import("navigation_definition.zig");
pub const handleDefinition = navigation_definition.handleDefinition;
const navigation_references = @import("navigation_references.zig");
pub const handleReferences = navigation_references.handleReferences;
const navigation_hierarchy = @import("navigation_hierarchy.zig");
pub const handleCallHierarchyPrepare = navigation_hierarchy.handleCallHierarchyPrepare;
pub const handleCallHierarchyIncomingCalls = navigation_hierarchy.handleCallHierarchyIncomingCalls;
pub const handleCallHierarchyOutgoingCalls = navigation_hierarchy.handleCallHierarchyOutgoingCalls;
pub const isRailsRoutesFile = nav_symbols.isRailsRoutesFile;

pub fn handleImplementation(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    if (self.isCancelled(msg.id)) return self.cancelledResponse(msg.id);
    const rtx = self.beginRead();
    defer rtx.end();
    const uri = extractTextDocumentUri(msg.params) orelse return emptyResult(msg);
    const pos = extractPosition(msg.params) orelse return emptyResult(msg);
    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);
    const source = self.readSourceForUri(uri, path) catch return emptyResult(msg);
    defer self.alloc.free(source);
    const offset = self.clientPosToOffset(source, pos.line, pos.character);
    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    // Find the parent class of the method at cursor to identify its context
    var parent_name: []const u8 = "";
    {
        const ctx_stmt = self.cachedStmt(
            \\SELECT s.parent_name FROM symbols s
            \\JOIN files f ON f.id = s.file_id
            \\WHERE f.path = ? AND s.name = ? AND s.kind IN ('def','classdef')
            \\LIMIT 1
        ) catch return emptyResult(msg);
        defer ctx_stmt.reset();
        ctx_stmt.bind_text(1, path);
        ctx_stmt.bind_text(2, word);
        if (ctx_stmt.step() catch false) {
            parent_name = ctx_stmt.column_text(0);
        }
    }

    // Find all overriding implementations: same method name in subclasses or includers
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var first = true;

    const impl_stmt = self.cachedStmt(
        \\SELECT s.name, s.line, s.col, f.path, s.parent_name
        \\FROM symbols s JOIN files f ON f.id = s.file_id
        \\WHERE s.name = ? AND s.kind IN ('def','classdef') AND s.parent_name != ?
        \\LIMIT 50
    ) catch {
        try w.writeByte(']');
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    };
    defer impl_stmt.reset();
    impl_stmt.bind_text(1, word);
    impl_stmt.bind_text(2, if (parent_name.len > 0) parent_name else "\x00");

    var frc_impl: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_impl.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_impl.deinit(self.alloc);
    }

    while (impl_stmt.step() catch false) {
        if (!first) try w.writeByte(',');
        first = false;
        const sym_name = impl_stmt.column_text(0);
        const sym_line = impl_stmt.column_int(1);
        const sym_col = impl_stmt.column_int(2);
        const sym_path = impl_stmt.column_text(3);
        const start_char = self.toClientColFromPath(&frc_impl, sym_path, sym_line - 1, sym_col);
        try writeLoc(w, sym_path, sym_line - 1, start_char, start_char + @as(u32, @intCast(sym_name.len)));
    }

    try w.writeByte(']');
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleTypeDefinition(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    const rtx = self.beginRead();
    defer rtx.end();
    const params = msg.params orelse return emptyResult(msg);
    const obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const td_val = obj.get("textDocument") orelse return emptyResult(msg);
    const td = switch (td_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const uri_val = td.get("uri") orelse return emptyResult(msg);
    const uri = switch (uri_val) {
        .string => |s| s,
        else => return emptyResult(msg),
    };
    const pos_val = obj.get("position") orelse return emptyResult(msg);
    const pos = switch (pos_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const line_val = pos.get("line") orelse return emptyResult(msg);
    const line: u32 = switch (line_val) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };
    const char_val = pos.get("character") orelse return emptyResult(msg);
    const character: u32 = switch (char_val) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    const source = self.readSourceForUri(uri, path) catch
        return emptyResult(msg);
    defer self.alloc.free(source);

    const offset = self.clientPosToOffset(source, line, character);
    const word = extractWord(source, offset);
    if (word.len == 0) return emptyResult(msg);

    const cursor_line: i64 = @intCast(line + 1); // 1-based for DB

    // Check local_vars for type_hint
    const file_stmt = try self.cachedStmt("SELECT id FROM files WHERE path = ?");
    defer file_stmt.reset();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) return emptyResult(msg);
    const file_id = file_stmt.column_int(0);

    var type_name: ?[]const u8 = null;

    // Type-bridge resolution wins when Sorbet/Steep has a high-confidence
    // type for `word`. Owned buffer freed at the end of this function via
    // `tn_owned`.
    var tn_owned: ?[]u8 = null;
    defer if (tn_owned) |b| self.alloc.free(b);
    if (type_resolver.resolve(self.alloc, self.queryDb(), word, null, -1)) |hit_const| {
        var hit = hit_const;
        defer hit.deinit(self.alloc);
        if (hit.confidence >= self.type_checker_confidence.surface) {
            tn_owned = type_resolver.stripWrapper(self.alloc, hit.type_str) catch null;
            if (tn_owned) |b| type_name = b;
        }
    }

    if (type_name == null) {
        const lv_stmt = try self.cachedStmt(
            \\SELECT type_hint FROM local_vars
            \\WHERE file_id = ? AND name = ? AND line <= ? AND type_hint IS NOT NULL
            \\ORDER BY line DESC LIMIT 1
        );
        defer lv_stmt.reset();
        lv_stmt.bind_int(1, file_id);
        lv_stmt.bind_text(2, word);
        lv_stmt.bind_int(3, cursor_line);
        if (try lv_stmt.step()) {
            tn_owned = try self.alloc.dupe(u8, lv_stmt.column_text(0));
            type_name = tn_owned;
        }
    }

    // If no local var, check if word is itself a class/module
    if (type_name == null) {
        type_name = word;
    }

    const tn = type_name.?;

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeByte('[');
    var found_any = false;
    var frc_td: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var frc_it = frc_td.iterator();
        while (frc_it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc_td.deinit(self.alloc);
    }

    const sym_stmt = try self.cachedStmt(
        \\SELECT s.name, s.line, s.col, f.path
        \\FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE (s.name = ? OR s.name LIKE '%::' || ?) AND s.kind IN ('class', 'module')
        \\ORDER BY CASE WHEN s.name = ? THEN 0 ELSE 1 END, s.id LIMIT 5
    );
    defer sym_stmt.reset();
    sym_stmt.bind_text(1, tn);
    sym_stmt.bind_text(2, tn);
    sym_stmt.bind_text(3, tn);
    while (try sym_stmt.step()) {
        if (found_any) try w.writeByte(',');
        found_any = true;
        const sym_name = sym_stmt.column_text(0);
        const sym_line = sym_stmt.column_int(1);
        const sym_col = sym_stmt.column_int(2);
        const sym_path = sym_stmt.column_text(3);
        const start_char = self.toClientColFromPath(&frc_td, sym_path, sym_line - 1, sym_col);
        try writeLoc(w, sym_path, sym_line - 1, start_char, start_char + @as(u32, @intCast(sym_name.len)));
    }
    try w.writeByte(']');

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

const type_hierarchy = @import("type_hierarchy.zig");
pub const handlePrepareTypeHierarchy = type_hierarchy.handlePrepareTypeHierarchy;
pub const handleTypeHierarchySupertypes = type_hierarchy.handleTypeHierarchySupertypes;
pub const handleTypeHierarchySubtypes = type_hierarchy.handleTypeHierarchySubtypes;
