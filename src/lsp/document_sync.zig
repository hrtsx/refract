const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const types = @import("types.zig");
const db_mod = @import("../db.zig");
const scanner = @import("../indexer/scanner.zig");
const indexer = @import("../indexer/index.zig");
const erb_mapping = @import("erb_mapping.zig");
const diagnostics = @import("diagnostics.zig");

const extractTextDocumentUri = S.extractTextDocumentUri;
const extractParamsObject = S.extractParamsObject;
const uriToPath = S.uriToPath;
const pathToUri = S.pathToUri;
const normalizeCRLF = S.normalizeCRLF;
const writeEscapedJson = S.writeEscapedJson;
const OPEN_DOC_CACHE_SIZE = S.OPEN_DOC_CACHE_SIZE;
const MAX_DELETED_PATHS = S.MAX_DELETED_PATHS;
const MAX_INCR_PATHS = S.MAX_INCR_PATHS;

pub fn handleDidSave(self: *Server, msg: types.RequestMessage) void {
    const params = msg.params orelse return;
    const obj = switch (params) {
        .object => |o| o,
        else => return,
    };
    const td_val = obj.get("textDocument") orelse return;
    const td = switch (td_val) {
        .object => |o| o,
        else => return,
    };
    const uri_val = td.get("uri") orelse return;
    const uri = switch (uri_val) {
        .string => |s| s,
        else => return,
    };
    const path = uriToPath(self.alloc, uri) catch return;
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return;
    if (self.isExcludedPath(path)) return;
    if (obj.get("text")) |tv| {
        if (tv == .string) {
            const raw_text = tv.string;
            const buf = self.alloc.dupe(u8, raw_text) catch null;
            if (buf) |b| {
                const norm = normalizeCRLF(b);
                const norm_owned = self.alloc.dupe(u8, norm) catch blk: {
                    self.alloc.free(b);
                    break :blk null;
                };
                self.alloc.free(b);
                if (norm_owned) |n| {
                    defer self.alloc.free(n);
                    var index_failed = false;
                    self.db_mutex.lockUncancelable(std.Options.debug_io);
                    indexer.indexSource(n, path, self.db, self.alloc) catch {
                        index_failed = true;
                    };
                    self.db_mutex.unlock(std.Options.debug_io);
                    if (index_failed) self.sendLogMessage(2, "refract: index failed on save");
                    self.env_keys_dirty.store(true, .release);
                    diagnostics.publishDiagnostics(self, uri, path, true);
                    return;
                }
            }
        }
    }
    const paths = [_][]const u8{path};
    var reindex_save_failed = false;
    self.db_mutex.lockUncancelable(std.Options.debug_io);
    indexer.reindex(self.db, &paths, false, self.alloc, self.max_file_size.load(.monotonic), null) catch {
        reindex_save_failed = true;
    };
    self.db_mutex.unlock(std.Options.debug_io);
    if (reindex_save_failed) self.sendLogMessage(2, "refract: reindex failed on save");
    self.env_keys_dirty.store(true, .release);
    diagnostics.publishDiagnostics(self, uri, path, true);
}

pub fn handleDidChange(self: *Server, msg: types.RequestMessage) void {
    const params = msg.params orelse return;
    const obj = switch (params) {
        .object => |o| o,
        else => return,
    };
    const td_val = obj.get("textDocument") orelse return;
    const td = switch (td_val) {
        .object => |o| o,
        else => return,
    };
    const uri_val = td.get("uri") orelse return;
    const uri = switch (uri_val) {
        .string => |s| s,
        else => return,
    };
    const incoming_version: i64 = if (td.get("version")) |v|
        switch (v) {
            .integer => |i| i,
            else => std.math.minInt(i64),
        }
    else
        std.math.minInt(i64);
    const changes_val = obj.get("contentChanges") orelse return;
    const changes = switch (changes_val) {
        .array => |a| a,
        else => return,
    };
    if (changes.items.len == 0) return;
    if (changes.items.len > 1) self.sendLogMessage(4, "refract: unexpected multiple contentChanges");
    const first = switch (changes.items[0]) {
        .object => |o| o,
        else => return,
    };
    const text_val = first.get("text") orelse return;
    const text = switch (text_val) {
        .string => |s| s,
        else => return,
    };

    const real_path = uriToPath(self.alloc, uri) catch return;
    defer self.alloc.free(real_path);
    if (!self.pathInBounds(real_path)) return;

    {
        const doc_key = self.alloc.dupe(u8, uri) catch return;
        const raw_val = self.alloc.dupe(u8, text) catch {
            self.alloc.free(doc_key);
            return;
        };
        const norm_val = normalizeCRLF(raw_val);
        var doc_val: []u8 = if (norm_val.len < raw_val.len)
            (self.alloc.realloc(raw_val, norm_val.len) catch blk: {
                defer self.alloc.free(raw_val);
                break :blk self.alloc.dupe(u8, norm_val) catch {
                    self.alloc.free(doc_key);
                    return;
                };
            })
        else
            raw_val;
        if (doc_val.len >= 3 and doc_val[0] == 0xEF and doc_val[1] == 0xBB and doc_val[2] == 0xBF) {
            const stripped = self.alloc.dupe(u8, doc_val[3..]) catch doc_val;
            if (stripped.ptr != doc_val.ptr) {
                self.alloc.free(doc_val);
                doc_val = stripped;
            }
        }
        self.open_docs_mu.lockUncancelable(std.Options.debug_io);
        defer self.open_docs_mu.unlock(std.Options.debug_io);
        const stored_version = self.open_docs_version.get(uri) orelse std.math.minInt(i64);
        if (incoming_version <= stored_version) {
            self.alloc.free(doc_key);
            self.alloc.free(doc_val);
            return;
        }
        const already_tracked = self.open_docs.contains(uri);
        if (self.open_docs.fetchRemove(doc_key)) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
        }
        _ = if (self.open_docs_version.fetchRemove(uri)) |old_ver| blk: {
            self.alloc.free(old_ver.key);
            break :blk {};
        } else {};
        const ver_key = self.alloc.dupe(u8, uri) catch {
            self.alloc.free(doc_key);
            self.alloc.free(doc_val);
            return;
        };
        self.open_docs_version.put(self.alloc, ver_key, incoming_version) catch self.alloc.free(ver_key);
        self.open_docs.put(self.alloc, doc_key, doc_val) catch {
            self.alloc.free(doc_key);
            self.alloc.free(doc_val);
        };
        if (!already_tracked) {
            const order_key2 = self.alloc.dupe(u8, uri) catch "";
            if (order_key2.len > 0) self.open_docs_order.append(self.alloc, order_key2) catch self.alloc.free(order_key2);
        }
        while (self.open_docs.count() > OPEN_DOC_CACHE_SIZE) {
            if (self.open_docs_order.items.len == 0) break;
            const lru_uri = self.open_docs_order.swapRemove(0);
            defer self.alloc.free(@constCast(lru_uri));
            if (self.open_docs.fetchRemove(lru_uri)) |evicted| {
                self.alloc.free(evicted.key);
                self.alloc.free(evicted.value);
            }
            if (self.open_docs_version.fetchRemove(lru_uri)) |old_ver| {
                self.alloc.free(old_ver.key);
            }
        }
    }
    // Mark URI dirty with current timestamp; flush happens lazily at query time
    const now_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
    {
        self.last_index_mu.lockUncancelable(std.Options.debug_io);
        defer self.last_index_mu.unlock(std.Options.debug_io);
        const gop = self.last_index_ms.getOrPut(uri) catch {
            diagnostics.publishDiagnostics(self, uri, real_path, false);
            return;
        };
        if (!gop.found_existing) {
            if (self.alloc.dupe(u8, uri)) |k| {
                gop.key_ptr.* = k;
            } else |_| {
                _ = self.last_index_ms.remove(uri);
            }
        }
        gop.value_ptr.* = now_ms;
    }
    diagnostics.publishDiagnostics(self, uri, real_path, false);
}

pub fn handleDidChangeWatchedFiles(self: *Server, msg: types.RequestMessage) void {
    const params = msg.params orelse return;
    const obj = switch (params) {
        .object => |o| o,
        else => return,
    };
    const changes_val = obj.get("changes") orelse return;
    const changes = switch (changes_val) {
        .array => |a| a,
        else => return,
    };

    var watched_overflow = false;
    for (changes.items) |change| {
        const c = switch (change) {
            .object => |o| o,
            else => continue,
        };
        const uri_val = c.get("uri") orelse continue;
        const uri = switch (uri_val) {
            .string => |s| s,
            else => continue,
        };
        const type_val = c.get("type") orelse continue;
        const change_type: i64 = switch (type_val) {
            .integer => |i| i,
            else => continue,
        };
        const path = uriToPath(self.alloc, uri) catch continue;
        if (!self.pathInBounds(path)) {
            self.alloc.free(path);
            continue;
        }
        defer self.alloc.free(path);
        const is_indexed = std.mem.endsWith(u8, path, ".rb") or
            std.mem.endsWith(u8, path, ".rbs") or
            std.mem.endsWith(u8, path, ".rbi") or
            std.mem.endsWith(u8, path, ".erb") or
            std.mem.endsWith(u8, path, ".haml") or
            std.mem.endsWith(u8, path, ".slim") or
            std.mem.endsWith(u8, path, ".rake") or
            std.mem.endsWith(u8, path, ".gemspec") or
            std.mem.endsWith(u8, path, ".ru") or
            std.mem.endsWith(u8, path, "/Rakefile") or
            std.mem.endsWith(u8, path, "/Gemfile");
        if (!is_indexed) continue;

        if (change_type == 3) {
            self.last_index_mu.lockUncancelable(std.Options.debug_io);
            if (self.last_index_ms.fetchRemove(uri)) |kv| self.alloc.free(kv.key);
            self.last_index_mu.unlock(std.Options.debug_io);
            self.incr_paths_mu.lockUncancelable(std.Options.debug_io);
            var incr_idx: usize = 0;
            while (incr_idx < self.incr_paths.items.len) {
                if (std.mem.eql(u8, self.incr_paths.items[incr_idx], path)) {
                    self.alloc.free(self.incr_paths.items[incr_idx]);
                    _ = self.incr_paths.swapRemove(incr_idx);
                } else {
                    incr_idx += 1;
                }
            }
            self.incr_paths_mu.unlock(std.Options.debug_io);
            // Mark path as explicitly deleted so background workers skip it
            self.deleted_paths_mu.lockUncancelable(std.Options.debug_io);
            if (self.alloc.dupe(u8, path)) |dp| {
                if (self.deleted_paths.count() < MAX_DELETED_PATHS) {
                    self.deleted_paths.put(self.alloc, dp, {}) catch self.alloc.free(dp);
                } else {
                    self.alloc.free(dp);
                }
            } else |_| {}
            self.deleted_paths_mu.unlock(std.Options.debug_io);
            self.db_mutex.lockUncancelable(std.Options.debug_io);
            self.db.begin() catch {
                self.db_mutex.unlock(std.Options.debug_io);
                continue;
            };
            const del = self.db.prepare("DELETE FROM files WHERE path = ?") catch |e| {
                self.logErr("delete file prepare", e);
                self.db.rollback() catch |re| self.logErr("rollback after prepare failure", re);
                self.db_mutex.unlock(std.Options.debug_io);
                continue;
            };
            del.bind_text(1, path);
            _ = del.step() catch |e| {
                self.logErr("delete file step", e);
                del.finalize();
                self.db.rollback() catch |re| self.logErr("rollback after step failure", re);
                self.db_mutex.unlock(std.Options.debug_io);
                continue;
            };
            del.finalize();
            self.db.commit() catch |e| {
                self.logErr("delete file commit", e);
                self.db.rollback() catch |re| self.logErr("rollback after commit failure", re);
            };
            self.db_mutex.unlock(std.Options.debug_io);
        } else {
            // Remove from deleted_paths if the file is being re-created/modified
            self.deleted_paths_mu.lockUncancelable(std.Options.debug_io);
            if (self.deleted_paths.fetchRemove(path)) |old_dp| self.alloc.free(old_dp.key);
            self.deleted_paths_mu.unlock(std.Options.debug_io);
            // Try synchronous reindex; if db_mutex is contended, queue for background
            if (self.db_mutex.tryLock()) {
                const paths_arr = [_][]const u8{path};
                _ = indexer.reindex(self.db, &paths_arr, false, self.alloc, self.max_file_size.load(.monotonic), null) catch |e| {
                    var buf: [128]u8 = undefined;
                    const m = std.fmt.bufPrint(&buf, "refract: reindex failed for watched file: {s}", .{@errorName(e)}) catch "refract: reindex failed for watched file";
                    self.sendLogMessage(2, m);
                };
                self.db_mutex.unlock(std.Options.debug_io);
            } else {
                const duped = self.alloc.dupe(u8, path) catch continue;
                self.incr_paths_mu.lockUncancelable(std.Options.debug_io);
                if (self.incr_paths.items.len < MAX_INCR_PATHS) {
                    self.incr_paths.append(self.alloc, duped) catch {
                        self.alloc.free(duped);
                        self.incr_paths_mu.unlock(std.Options.debug_io);
                        continue;
                    };
                } else {
                    self.alloc.free(duped);
                    watched_overflow = true;
                }
                self.incr_paths_mu.unlock(std.Options.debug_io);
            }
        }
    }
    if (watched_overflow) {
        self.showUserError("refract: file change queue full — some files skipped. Run Refract: Force Reindex.");
        self.startBgIndexer();
    }
}

pub fn handleDidOpen(self: *Server, msg: types.RequestMessage) void {
    const params = msg.params orelse return;
    const obj = switch (params) {
        .object => |o| o,
        else => return,
    };
    const td_val = obj.get("textDocument") orelse return;
    const td = switch (td_val) {
        .object => |o| o,
        else => return,
    };
    const uri_val = td.get("uri") orelse return;
    const uri = switch (uri_val) {
        .string => |s| s,
        else => return,
    };
    const path = uriToPath(self.alloc, uri) catch return;
    defer self.alloc.free(path);
    if (!self.pathInBounds(path)) return;
    if (td.get("text")) |txt_val| {
        if (txt_val == .string) {
            var index_open_err: ?[]const u8 = null;
            var index_open_err_buf: [512]u8 = undefined;
            self.db_mutex.lockUncancelable(std.Options.debug_io);
            indexer.indexSource(txt_val.string, path, self.db, self.alloc) catch |e| {
                index_open_err = std.fmt.bufPrint(&index_open_err_buf, "refract: index failed for {s}: {s}", .{ path, @errorName(e) }) catch "refract: index failed";
            };
            self.db_mutex.unlock(std.Options.debug_io);
            if (index_open_err) |msg_str| self.sendLogMessage(2, msg_str);
            const doc_key = self.alloc.dupe(u8, uri) catch return;
            const raw_val = self.alloc.dupe(u8, txt_val.string) catch {
                self.alloc.free(doc_key);
                return;
            };
            const norm_val = normalizeCRLF(raw_val);
            var doc_val: []u8 = if (norm_val.len < raw_val.len)
                (self.alloc.realloc(raw_val, norm_val.len) catch blk: {
                    defer self.alloc.free(raw_val);
                    break :blk self.alloc.dupe(u8, norm_val) catch {
                        self.alloc.free(doc_key);
                        return;
                    };
                })
            else
                raw_val;
            if (doc_val.len >= 3 and doc_val[0] == 0xEF and doc_val[1] == 0xBB and doc_val[2] == 0xBF) {
                const stripped = self.alloc.dupe(u8, doc_val[3..]) catch doc_val;
                if (stripped.ptr != doc_val.ptr) {
                    self.alloc.free(doc_val);
                    doc_val = stripped;
                }
            }
            self.open_docs_mu.lockUncancelable(std.Options.debug_io);
            defer self.open_docs_mu.unlock(std.Options.debug_io);
            if (self.open_docs.fetchRemove(doc_key)) |old| {
                self.alloc.free(old.key);
                self.alloc.free(old.value);
            }
            self.open_docs.put(self.alloc, doc_key, doc_val) catch {
                self.alloc.free(doc_key);
                self.alloc.free(doc_val);
                return;
            };
            const open_version: i64 = if (td.get("version")) |v|
                switch (v) {
                    .integer => |i| i,
                    else => std.math.minInt(i64),
                }
            else
                std.math.minInt(i64);
            _ = if (self.open_docs_version.fetchRemove(uri)) |old_ver| blk: {
                self.alloc.free(old_ver.key);
                break :blk {};
            } else {};
            const ver_key2 = self.alloc.dupe(u8, uri) catch "";
            if (ver_key2.len > 0) self.open_docs_version.put(self.alloc, ver_key2, open_version) catch self.alloc.free(ver_key2);
            const order_key = self.alloc.dupe(u8, uri) catch "";
            if (order_key.len > 0) self.open_docs_order.append(self.alloc, order_key) catch self.alloc.free(order_key);
            while (self.open_docs.count() > OPEN_DOC_CACHE_SIZE) {
                if (self.open_docs_order.items.len == 0) break;
                const oldest = self.open_docs_order.swapRemove(0);
                defer self.alloc.free(@constCast(oldest));
                if (self.open_docs.fetchRemove(oldest)) |old| {
                    self.alloc.free(old.key);
                    self.alloc.free(old.value);
                }
                if (self.open_docs_version.fetchRemove(oldest)) |old_ver| {
                    self.alloc.free(old_ver.key);
                }
            }
        }
    } else {
        const paths = [_][]const u8{path};
        var reindex_open_failed = false;
        self.db_mutex.lockUncancelable(std.Options.debug_io);
        indexer.reindex(self.db, &paths, false, self.alloc, self.max_file_size.load(.monotonic), null) catch {
            reindex_open_failed = true;
        };
        self.db_mutex.unlock(std.Options.debug_io);
        if (reindex_open_failed) self.sendLogMessage(2, "refract: reindex failed on open");
    }
    diagnostics.publishDiagnostics(self, uri, path, false);
}

pub fn handleDidClose(self: *Server, msg: types.RequestMessage) void {
    const params = msg.params orelse return;
    const obj = switch (params) {
        .object => |o| o,
        else => return,
    };
    const td_val = obj.get("textDocument") orelse return;
    const td = switch (td_val) {
        .object => |o| o,
        else => return,
    };
    const uri_val = td.get("uri") orelse return;
    const uri = switch (uri_val) {
        .string => |s| s,
        else => return,
    };
    {
        self.open_docs_mu.lockUncancelable(std.Options.debug_io);
        defer self.open_docs_mu.unlock(std.Options.debug_io);
        if (self.open_docs.fetchRemove(uri)) |old| {
            self.alloc.free(old.key);
            self.alloc.free(old.value);
        }
        if (self.open_docs_version.fetchRemove(uri)) |old_ver| self.alloc.free(old_ver.key);
        var i: usize = self.open_docs_order.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.open_docs_order.items[i], uri)) {
                const removed = self.open_docs_order.swapRemove(i);
                self.alloc.free(@constCast(removed));
                break;
            }
        }
    }
    self.last_index_mu.lockUncancelable(std.Options.debug_io);
    if (self.last_index_ms.fetchRemove(uri)) |kv| self.alloc.free(kv.key);
    self.last_index_mu.unlock(std.Options.debug_io);
    {
        const close_path = uriToPath(self.alloc, uri) catch return;
        defer self.alloc.free(close_path);
        if (self.pathInBounds(close_path)) {
            const paths = [_][]const u8{close_path};
            var close_err: ?[]const u8 = null;
            var close_err_buf: [512]u8 = undefined;
            self.db_mutex.lockUncancelable(std.Options.debug_io);
            indexer.reindex(self.db, &paths, false, self.alloc, self.max_file_size.load(.monotonic), null) catch |e| {
                close_err = std.fmt.bufPrint(&close_err_buf, "refract: index failed for {s}: {s}", .{ close_path, @errorName(e) }) catch "refract: index failed";
            };
            self.db_mutex.unlock(std.Options.debug_io);
            if (close_err) |msg_str| self.sendLogMessage(2, msg_str);
        }
    }
    var aw = std.Io.Writer.Allocating.init(self.alloc);
    const w = &aw.writer;
    w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch return;
    writeEscapedJson(w, uri) catch return;
    w.writeAll(",\"diagnostics\":[]}}") catch return;
    const json = aw.toOwnedSlice() catch return;
    defer self.alloc.free(json);
    self.sendNotification(json);
}

pub fn handleDidCreateFiles(self: *Server, msg: types.RequestMessage) void {
    const params = msg.params orelse return;
    const obj = switch (params) {
        .object => |o| o,
        else => return,
    };
    const files_val = obj.get("files") orelse return;
    const files = switch (files_val) {
        .array => |a| a,
        else => return,
    };

    for (files.items) |file| {
        const f = switch (file) {
            .object => |o| o,
            else => continue,
        };
        const uri_val = f.get("uri") orelse continue;
        const uri = switch (uri_val) {
            .string => |s| s,
            else => continue,
        };
        const path = uriToPath(self.alloc, uri) catch continue;
        defer self.alloc.free(path);
        const is_indexed = std.mem.endsWith(u8, path, ".rb") or
            std.mem.endsWith(u8, path, ".rbs") or
            std.mem.endsWith(u8, path, ".rbi") or
            std.mem.endsWith(u8, path, ".erb") or
            std.mem.endsWith(u8, path, ".haml") or
            std.mem.endsWith(u8, path, ".slim") or
            std.mem.endsWith(u8, path, ".rake") or
            std.mem.endsWith(u8, path, ".gemspec") or
            std.mem.endsWith(u8, path, ".ru") or
            std.mem.endsWith(u8, path, "/Rakefile") or
            std.mem.endsWith(u8, path, "/Gemfile");
        if (!is_indexed) continue;
        const paths = [_][]const u8{path};
        self.db_mutex.lockUncancelable(std.Options.debug_io);
        indexer.reindex(self.db, &paths, false, self.alloc, self.max_file_size.load(.monotonic), null) catch self.sendLogMessage(2, "refract: reindex failed");
        self.db_mutex.unlock(std.Options.debug_io);
    }
}

pub fn handleDidDeleteFiles(self: *Server, msg: types.RequestMessage) void {
    const params = msg.params orelse return;
    const obj = switch (params) {
        .object => |o| o,
        else => return,
    };
    const files_val = obj.get("files") orelse return;
    const files = switch (files_val) {
        .array => |a| a,
        else => return,
    };

    for (files.items) |file| {
        const f = switch (file) {
            .object => |o| o,
            else => continue,
        };
        const uri_val = f.get("uri") orelse continue;
        const uri = switch (uri_val) {
            .string => |s| s,
            else => continue,
        };
        const path = uriToPath(self.alloc, uri) catch continue;
        defer self.alloc.free(path);
        self.db_mutex.lockUncancelable(std.Options.debug_io);
        const sel = self.db.prepare("SELECT id FROM files WHERE path = ?") catch {
            self.db_mutex.unlock(std.Options.debug_io);
            continue;
        };
        sel.bind_text(1, path);
        const file_id: ?i64 = if (sel.step() catch false) sel.column_int(0) else null;
        sel.finalize();
        if (file_id) |fid| {
            const dels = [_][*:0]const u8{
                "DELETE FROM sem_tokens WHERE file_id = ?",
                "DELETE FROM local_vars WHERE file_id = ?",
                "DELETE FROM refs WHERE file_id = ?",
                "DELETE FROM symbols WHERE file_id = ?",
                "DELETE FROM files WHERE id = ?",
            };
            for (dels) |sql| {
                const st = self.db.prepare(sql) catch continue;
                st.bind_int(1, fid);
                _ = st.step() catch |e| {
                    var buf: [128]u8 = undefined;
                    const m = std.fmt.bufPrint(&buf, "refract: rename symbol update failed: {s}", .{@errorName(e)}) catch "refract: rename symbol update failed";
                    self.sendLogMessage(2, m);
                };
                st.finalize();
            }
        }
        self.db_mutex.unlock(std.Options.debug_io);
        // Remove from incr_paths so flushIncrPaths doesn't re-add deleted files
        self.incr_paths_mu.lockUncancelable(std.Options.debug_io);
        var ip_idx: usize = 0;
        while (ip_idx < self.incr_paths.items.len) {
            if (std.mem.eql(u8, self.incr_paths.items[ip_idx], path)) {
                self.alloc.free(self.incr_paths.items[ip_idx]);
                _ = self.incr_paths.orderedRemove(ip_idx);
            } else {
                ip_idx += 1;
            }
        }
        self.incr_paths_mu.unlock(std.Options.debug_io);
        // Mark as explicitly deleted so background scan workers skip it
        self.deleted_paths_mu.lockUncancelable(std.Options.debug_io);
        if (self.alloc.dupe(u8, path)) |dp| {
            if (self.deleted_paths.count() < MAX_DELETED_PATHS) {
                self.deleted_paths.put(self.alloc, dp, {}) catch self.alloc.free(dp);
            } else {
                self.alloc.free(dp);
            }
        } else |_| {}
        self.deleted_paths_mu.unlock(std.Options.debug_io);
        var aw2 = std.Io.Writer.Allocating.init(self.alloc);
        const w2 = &aw2.writer;
        w2.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch continue;
        writeEscapedJson(w2, uri) catch {
            aw2.deinit();
            continue;
        };
        w2.writeAll(",\"diagnostics\":[]}}") catch {
            aw2.deinit();
            continue;
        };
        const json2 = aw2.toOwnedSlice() catch continue;
        defer self.alloc.free(json2);
        self.sendNotification(json2);
    }
}

pub fn handleDidRenameFiles(self: *Server, msg: types.RequestMessage) void {
    const params = msg.params orelse return;
    const obj = switch (params) {
        .object => |o| o,
        else => return,
    };
    const files_val = obj.get("files") orelse return;
    const files = switch (files_val) {
        .array => |a| a.items,
        else => return,
    };
    for (files) |f| {
        const fobj = switch (f) {
            .object => |o| o,
            else => continue,
        };
        const old_uri = switch (fobj.get("oldUri") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const new_uri = switch (fobj.get("newUri") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const old_path = uriToPath(self.alloc, old_uri) catch continue;
        defer self.alloc.free(old_path);
        const new_path = uriToPath(self.alloc, new_uri) catch continue;
        defer self.alloc.free(new_path);
        const stmt = self.db.prepare("UPDATE files SET path=? WHERE path=?") catch continue;
        defer stmt.finalize();
        stmt.bind_text(1, new_path);
        stmt.bind_text(2, old_path);
        _ = stmt.step() catch |e| {
            var buf: [128]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "refract: rename symbol update failed: {s}", .{@errorName(e)}) catch "refract: rename symbol update failed";
            self.sendLogMessage(2, m);
        };
        var aw3 = std.Io.Writer.Allocating.init(self.alloc);
        const w3 = &aw3.writer;
        w3.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":") catch continue;
        writeEscapedJson(w3, old_uri) catch {
            aw3.deinit();
            continue;
        };
        w3.writeAll(",\"diagnostics\":[]}}") catch {
            aw3.deinit();
            continue;
        };
        const json3 = aw3.toOwnedSlice() catch continue;
        defer self.alloc.free(json3);
        self.sendNotification(json3);
    }
}
