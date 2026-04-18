const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractPosition = S.extractPosition;
const emptyResult = S.emptyResult;
const uriToPath = S.uriToPath;
const convertSemBlobToUtf16 = S.convertSemBlobToUtf16;
const setMetaInt = S.setMetaInt;
const getMetaInt = S.getMetaInt;

pub fn handleSemanticTokensFull(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.db_mutex.lockUncancelable(std.Options.debug_io);
    defer self.db_mutex.unlock(std.Options.debug_io);
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

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return emptyResult(msg);

    // Look up file_id
    const file_stmt = try self.db.prepare("SELECT id, mtime FROM files WHERE path = ?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) {
        var aw2 = std.Io.Writer.Allocating.init(self.alloc);
        try aw2.writer.writeAll("{\"resultId\":\"0\",\"data\":[]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
    }
    const file_id = file_stmt.column_int(0);
    const file_mtime = file_stmt.column_int(1);
    var mtime_buf: [32]u8 = undefined;
    const result_id = std.fmt.bufPrint(&mtime_buf, "{d}", .{file_mtime}) catch "0";

    const tok_stmt = try self.db.prepare("SELECT blob FROM sem_tokens WHERE file_id = ?");
    defer tok_stmt.finalize();
    tok_stmt.bind_int(1, file_id);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.print("{{\"resultId\":\"{s}\",\"data\":[", .{result_id});

    if (try tok_stmt.step()) {
        var blob = tok_stmt.column_blob(0);
        var conv_blob: ?[]u8 = null;
        defer if (conv_blob) |b| self.alloc.free(b);
        if (!self.encoding_utf8) {
            if (self.readSourceForUri(uri, path)) |src| {
                defer self.alloc.free(src);
                conv_blob = convertSemBlobToUtf16(blob, src, self.alloc) catch null;
                if (conv_blob) |b| blob = b;
            } else |_| {}
        }
        const count = blob.len / 4;
        var first = true;
        for (0..count) |idx| {
            if (!first) try w.writeByte(',');
            first = false;
            const val = std.mem.readInt(u32, blob[idx * 4 ..][0..4], .little);
            try w.print("{d}", .{val});
        }
        // Store token count for delta accuracy
        const u32_count = blob.len / 4;
        const token_count: i64 = @intCast(u32_count / 5);
        var meta_key_buf: [64]u8 = undefined;
        const meta_key = std.fmt.bufPrint(&meta_key_buf, "sem_token_count_{d}", .{file_id}) catch "sem_token_count_0";
        setMetaInt(self.db, meta_key, token_count, self.alloc);
    }

    try w.writeAll("]}");

    return types.ResponseMessage{
        .id = msg.id,
        .result = null,
        .raw_result = try aw.toOwnedSlice(),
        .@"error" = null,
    };
}

pub fn handleSemanticTokensRange(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.db_mutex.lockUncancelable(std.Options.debug_io);
    defer self.db_mutex.unlock(std.Options.debug_io);
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
    const range_val = obj.get("range") orelse return emptyResult(msg);
    const range_obj = switch (range_val) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const start_obj = switch (range_obj.get("start") orelse return emptyResult(msg)) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const end_obj = switch (range_obj.get("end") orelse return emptyResult(msg)) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const start_line: u32 = switch (start_obj.get("line") orelse return emptyResult(msg)) {
        .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };
    const end_line: u32 = switch (end_obj.get("line") orelse return emptyResult(msg)) {
        .integer => |i| if (i >= 0) @intCast(i) else return emptyResult(msg),
        else => return emptyResult(msg),
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);

    const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path = ?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) {
        var aw2 = std.Io.Writer.Allocating.init(self.alloc);
        try aw2.writer.writeAll("{\"data\":[]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
    }
    const file_id = file_stmt.column_int(0);

    const tok_stmt = try self.db.prepare("SELECT blob FROM sem_tokens WHERE file_id = ?");
    defer tok_stmt.finalize();
    tok_stmt.bind_int(1, file_id);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    try w.writeAll("{\"data\":[");

    if (try tok_stmt.step()) {
        var blob = tok_stmt.column_blob(0);
        var conv_blob_r: ?[]u8 = null;
        defer if (conv_blob_r) |b| self.alloc.free(b);
        if (!self.encoding_utf8) {
            if (self.readSourceForUri(uri, path)) |src| {
                defer self.alloc.free(src);
                conv_blob_r = convertSemBlobToUtf16(blob, src, self.alloc) catch null;
                if (conv_blob_r) |b| blob = b;
            } else |_| {}
        }
        const num_tokens = blob.len / 20;
        // Decode absolute positions and collect filtered tokens as flat u32 array
        // 5 values per token: abs_line, abs_col, len, tt, tm
        const max_filtered = num_tokens * 5;
        const filtered_buf = try self.alloc.alloc(u32, max_filtered);
        defer self.alloc.free(filtered_buf);
        var filtered_count: usize = 0;
        var abs_line: u32 = 0;
        var abs_col: u32 = 0;
        for (0..num_tokens) |i| {
            const dl = std.mem.readInt(u32, blob[i * 20 + 0 ..][0..4], .little);
            const dc = std.mem.readInt(u32, blob[i * 20 + 4 ..][0..4], .little);
            const len = std.mem.readInt(u32, blob[i * 20 + 8 ..][0..4], .little);
            const tt = std.mem.readInt(u32, blob[i * 20 + 12 ..][0..4], .little);
            const tm = std.mem.readInt(u32, blob[i * 20 + 16 ..][0..4], .little);
            abs_line += dl;
            abs_col = if (dl == 0) abs_col + dc else dc;
            if (abs_line >= start_line and abs_line <= end_line) {
                filtered_buf[filtered_count * 5 + 0] = abs_line;
                filtered_buf[filtered_count * 5 + 1] = abs_col;
                filtered_buf[filtered_count * 5 + 2] = len;
                filtered_buf[filtered_count * 5 + 3] = tt;
                filtered_buf[filtered_count * 5 + 4] = tm;
                filtered_count += 1;
            }
        }
        // Re-encode filtered tokens as delta sequence
        var prev_line: u32 = start_line;
        var prev_col: u32 = 0;
        var first = true;
        for (0..filtered_count) |i| {
            const tok_line = filtered_buf[i * 5 + 0];
            const tok_col = filtered_buf[i * 5 + 1];
            const tok_len = filtered_buf[i * 5 + 2];
            const tok_tt = filtered_buf[i * 5 + 3];
            const tok_tm = filtered_buf[i * 5 + 4];
            if (!first) try w.writeByte(',');
            first = false;
            const out_dl = tok_line - prev_line;
            const out_dc = if (out_dl == 0) tok_col - prev_col else tok_col;
            try w.print("{d},{d},{d},{d},{d}", .{ out_dl, out_dc, tok_len, tok_tt, tok_tm });
            prev_line = tok_line;
            prev_col = tok_col;
        }
    }

    try w.writeAll("]}");
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}

pub fn handleSemanticTokensDelta(self: *Server, msg: types.RequestMessage) !?types.ResponseMessage {
    self.db_mutex.lockUncancelable(std.Options.debug_io);
    defer self.db_mutex.unlock(std.Options.debug_io);
    const params = msg.params orelse return emptyResult(msg);
    const obj = switch (params) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const td = switch (obj.get("textDocument") orelse return emptyResult(msg)) {
        .object => |o| o,
        else => return emptyResult(msg),
    };
    const uri = switch (td.get("uri") orelse return emptyResult(msg)) {
        .string => |s| s,
        else => return emptyResult(msg),
    };
    const prev_id: []const u8 = switch (obj.get("previousResultId") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };

    const path = uriToPath(self.alloc, uri) catch return emptyResult(msg);
    defer self.alloc.free(path);

    const file_stmt = try self.db.prepare("SELECT id FROM files WHERE path=?");
    defer file_stmt.finalize();
    file_stmt.bind_text(1, path);
    if (!(try file_stmt.step())) {
        var aw2 = std.Io.Writer.Allocating.init(self.alloc);
        try aw2.writer.writeAll("{\"resultId\":\"0\",\"edits\":[]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
    }
    const file_id = file_stmt.column_int(0);

    // Get current mtime from files table
    const mtime_stmt = try self.db.prepare("SELECT mtime FROM files WHERE id=?");
    defer mtime_stmt.finalize();
    mtime_stmt.bind_int(1, file_id);
    const mtime: i64 = if (try mtime_stmt.step()) mtime_stmt.column_int(0) else 0;
    var mtime_buf: [32]u8 = undefined;
    const result_id = std.fmt.bufPrint(&mtime_buf, "{d}", .{mtime}) catch "0";

    if (std.mem.eql(u8, prev_id, result_id)) {
        // No change
        var aw2 = std.Io.Writer.Allocating.init(self.alloc);
        try aw2.writer.print("{{\"resultId\":\"{s}\",\"edits\":[]}}", .{result_id});
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
    }

    // Load current blob and prev_blob for real diff
    const tok_stmt = try self.db.prepare("SELECT blob, prev_blob FROM sem_tokens WHERE file_id=?");
    defer tok_stmt.finalize();
    tok_stmt.bind_int(1, file_id);

    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    if (!(try tok_stmt.step())) {
        try w.print("{{\"resultId\":\"{s}\",\"edits\":[]}}", .{result_id});
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
    }
    const new_blob = tok_stmt.column_blob(0);
    const prev_blob_raw = tok_stmt.column_blob(1);

    const new_u32 = new_blob.len / 4;
    const old_u32 = if (prev_blob_raw.len > 0) prev_blob_raw.len / 4 else 0;

    if (!self.encoding_utf8) {
        var aw2 = std.Io.Writer.Allocating.init(self.alloc);
        const w2 = &aw2.writer;
        try w2.print("{{\"resultId\":\"{s}\",\"data\":[", .{result_id});
        var out_blob = new_blob;
        var conv2: ?[]u8 = null;
        defer if (conv2) |b| self.alloc.free(b);
        if (self.readSourceForUri(uri, path)) |src| {
            defer self.alloc.free(src);
            conv2 = convertSemBlobToUtf16(new_blob, src, self.alloc) catch null;
            if (conv2) |b| out_blob = b;
        } else |_| {}
        for (0..out_blob.len / 4) |idx| {
            if (idx > 0) try w2.writeByte(',');
            try w2.print("{d}", .{std.mem.readInt(u32, out_blob[idx * 4 ..][0..4], .little)});
        }
        try w2.writeAll("]}");
        return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw2.toOwnedSlice(), .@"error" = null };
    }

    if (old_u32 == 0) {
        if (prev_id.len > 0) {
            // Editor had tokens we can't diff against — return full SemanticTokens
            var aw2 = std.Io.Writer.Allocating.init(self.alloc);
            const w2 = &aw2.writer;
            try w2.print("{{\"resultId\":\"{s}\",\"data\":[", .{result_id});
            for (0..new_u32) |idx| {
                if (idx > 0) try w2.writeByte(',');
                try w2.print("{d}", .{std.mem.readInt(u32, new_blob[idx * 4 ..][0..4], .little)});
            }
            try w2.writeAll("]}");
            return types.ResponseMessage{
                .id = msg.id,
                .result = null,
                .raw_result = try aw2.toOwnedSlice(),
                .@"error" = null,
            };
        }
        // prev_id empty → initial request → delta insert at 0 is correct
        try w.print("{{\"resultId\":\"{s}\",\"edits\":[{{\"start\":0,\"deleteCount\":0,\"data\":[", .{result_id});
        for (0..new_u32) |idx| {
            if (idx > 0) try w.writeByte(',');
            try w.print("{d}", .{std.mem.readInt(u32, new_blob[idx * 4 ..][0..4], .little)});
        }
        try w.writeAll("]}]}");
    } else {
        // Find first and last differing u32 index
        var first_diff: usize = 0;
        while (first_diff < @min(new_u32, old_u32)) : (first_diff += 1) {
            const nv = std.mem.readInt(u32, new_blob[first_diff * 4 ..][0..4], .little);
            const ov = std.mem.readInt(u32, prev_blob_raw[first_diff * 4 ..][0..4], .little);
            if (nv != ov) break;
        }
        if (first_diff == new_u32 and first_diff == old_u32) {
            // Identical
            try w.print("{{\"resultId\":\"{s}\",\"edits\":[]}}", .{result_id});
        } else {
            var last_new = new_u32;
            var last_old = old_u32;
            while (last_new > first_diff and last_old > first_diff) {
                const nv = std.mem.readInt(u32, new_blob[(last_new - 1) * 4 ..][0..4], .little);
                const ov = std.mem.readInt(u32, prev_blob_raw[(last_old - 1) * 4 ..][0..4], .little);
                if (nv != ov) break;
                last_new -= 1;
                last_old -= 1;
            }
            const delete_count = last_old - first_diff;
            try w.print("{{\"resultId\":\"{s}\",\"edits\":[{{\"start\":{d},\"deleteCount\":{d},\"data\":[", .{ result_id, first_diff, delete_count });
            for (first_diff..last_new) |idx| {
                if (idx > first_diff) try w.writeByte(',');
                try w.print("{d}", .{std.mem.readInt(u32, new_blob[idx * 4 ..][0..4], .little)});
            }
            try w.writeAll("]}]}");
        }
    }
    return types.ResponseMessage{ .id = msg.id, .result = null, .raw_result = try aw.toOwnedSlice(), .@"error" = null };
}
