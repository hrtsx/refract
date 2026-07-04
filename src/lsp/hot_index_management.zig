const std = @import("std");
const S = @import("server.zig");
const Server = S.Server;
const db_mod = @import("../db.zig");
const hot_index_mod = @import("hot_index.zig");
const navigation = @import("navigation.zig");
const completion = @import("completion.zig");
const server_util = @import("server_util.zig");
const server_indexing = @import("server_indexing.zig");

const writeEscapedJson = server_util.writeEscapedJson;
const writeEscapedJsonContent = server_util.writeEscapedJsonContent;
const writePathAsUri = server_util.writePathAsUri;

pub fn rebuildHotIndex(self: *Server) void {
    if (!self.hot_index_enabled.load(.monotonic)) return;

    const profiling = std.c.getenv("REFRACT_INIT_PROFILE") != null;
    const hot_start = if (profiling) std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() else 0;

    var ro_db = db_mod.Db.openReadOnly(self.db_pathz) catch |e| {
        var ebuf: [256]u8 = undefined;
        const emsg = std.fmt.bufPrint(&ebuf, "refract: hot index warmup RO db open failed: {s}", .{@errorName(e)}) catch "refract: hot index warmup RO db open failed";
        self.sendLogMessage(2, emsg);
        return;
    };
    defer ro_db.close();

    const new_idx = hot_index_mod.buildFromDb(self.alloc, ro_db) catch |e| {
        var ebuf: [256]u8 = undefined;
        const emsg = std.fmt.bufPrint(&ebuf, "refract: hot index rebuild failed: {s}", .{@errorName(e)}) catch "refract: hot index rebuild failed";
        self.sendLogMessage(2, emsg);
        return;
    };

    // Pre-render hover bodies for the top-N most-referenced symbols (W1.1).
    // Runs before the new HotIndex is published, so no reader races; failures
    // are non-fatal (we just skip the cache).
    preRenderHotHover(self, new_idx, ro_db) catch |e| {
        var pbuf: [256]u8 = undefined;
        const pmsg = std.fmt.bufPrint(&pbuf, "refract: hover pre-render skipped: {s}", .{@errorName(e)}) catch "refract: hover pre-render skipped";
        self.sendLogMessage(3, pmsg);
    };

    // Pre-render goto-definition JSON for the same top-N hot symbols. Cuts
    // micro-def p50 down to the hover path's ballpark by skipping the
    // mutex+SQL+toClientColFromPath round-trip on hot names. (W1.2 / PR1)
    preRenderHotDef(self, new_idx) catch |e| {
        var pbuf: [256]u8 = undefined;
        const pmsg = std.fmt.bufPrint(&pbuf, "refract: def pre-render skipped: {s}", .{@errorName(e)}) catch "refract: def pre-render skipped";
        self.sendLogMessage(3, pmsg);
    };

    // Pre-render completion item bodies (everything except `textEdit`) for
    // unambiguous symbols. Cuts micro-completion p50 by collapsing the per-item
    // JSON build (~10 writes, kind/sort branching, snippet generator) down to
    // one memcpy + a 3-print textEdit suffix.
    preRenderHotCompletion(self, new_idx) catch |e| {
        var pbuf: [256]u8 = undefined;
        const pmsg = std.fmt.bufPrint(&pbuf, "refract: completion pre-render skipped: {s}", .{@errorName(e)}) catch "refract: completion pre-render skipped";
        self.sendLogMessage(3, pmsg);
    };

    self.hot_mu.lockUncancelable(std.Options.debug_io);
    defer self.hot_mu.unlock(std.Options.debug_io);

    // Guard against shutdown racing past us: if the server is winding down,
    // its deinit has already torn down the hot slot. Storing here would leak
    // because deinit's mutex section already ran. Free locally and bail.
    if (self.bg_cancelled.load(.acquire)) {
        new_idx.deinit();
        self.alloc.destroy(new_idx);
        return;
    }

    if (self.hot.load(.acquire)) |old| {
        old.deinit();
        self.alloc.destroy(old);
    }
    self.hot.store(new_idx, .release);

    // Return freed pages to the OS. buildFromDb allocates large temporary
    // name/tail/method lists (freed by the time we get here) and, on a rebuild,
    // we just freed the previous whole-repo arena. glibc retains both on its
    // freelist otherwise — trimming here collapses the first-cold-start build
    // spike (old==null path, which the previous guard skipped) as well.
    server_indexing.mallocTrim();

    if (profiling) {
        const hot_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - hot_start;
        var pbuf: [128]u8 = undefined;
        const pmsg = std.fmt.bufPrint(&pbuf, "refract_profile: rebuildHotIndex={d}ms symbols={d}\n", .{ hot_ms, new_idx.symbol_count }) catch "refract_profile: rebuildHotIndex\n";
        self.sendLogMessage(3, pmsg);
    }

    var ibuf: [128]u8 = undefined;
    const imsg = std.fmt.bufPrint(&ibuf, "refract: hot index built ({d} symbols, {d} files)", .{ new_idx.symbol_count, new_idx.file_count }) catch "refract: hot index built";
    self.sendLogMessage(3, imsg);
}

const PRE_RENDER_TOP_N: usize = 1000;

/// Pre-render hover bodies for the top-N most-referenced def/classdef
/// symbols whose name is unambiguous (single entry in name_map). Each body
/// is the JSON-escaped value that goes between `"value":"` and `"` in the
/// hover response; the hot-path can copy it verbatim and skip the per-call
/// markdown composer.
///
/// Skipped silently when:
///   - the symbol has overloads (multiple defs sharing the name)
///   - file_id has no path
///   - the symbol kind is not def/classdef
fn preRenderHotHover(self: *Server, hot: *hot_index_mod.HotIndex, db: db_mod.Db) !void {
    const stmt = db.prepare(
        "SELECT name, COUNT(*) AS c FROM refs GROUP BY name ORDER BY c DESC LIMIT " ++ std.fmt.comptimePrint("{d}", .{PRE_RENDER_TOP_N}),
    ) catch return;
    defer stmt.finalize();

    const arena = hot.arena.allocator();
    var rendered: u32 = 0;

    while (stmt.step() catch false) {
        const name = stmt.column_text(0);
        if (name.len == 0) continue;
        const syms = hot.lookupName(name);
        if (syms.len == 0) continue;

        // Pick the single def/classdef. If multiple match, skip (ambiguous).
        var picked: ?hot_index_mod.HotSymbol = null;
        var def_count: u32 = 0;
        for (syms) |s| {
            if (s.kind != .def and s.kind != .classdef) continue;
            picked = s;
            def_count += 1;
        }
        if (def_count != 1) continue;
        const hs = picked.?;

        const sym_path = hot.pathFor(hs.file_id) orelse continue;

        var aw = std.Io.Writer.Allocating.init(self.alloc);
        defer aw.deinit();
        const w = &aw.writer;
        const kind_label: []const u8 = if (hs.kind == .classdef) "def self" else "def";

        w.writeAll("*(") catch continue;
        writeEscapedJsonContent(w, kind_label) catch continue;
        w.writeAll(")* `") catch continue;
        writeEscapedJsonContent(w, name) catch continue;
        if (hs.params_sig) |sig| {
            if (sig.len > 0) {
                w.writeAll("(") catch continue;
                writeEscapedJsonContent(w, sig) catch continue;
                w.writeAll(")") catch continue;
            }
        }
        w.writeByte('`') catch continue;
        if (hs.return_type) |rt| {
            if (rt.len > 0) {
                w.writeAll(" \\u2192 ") catch continue;
                writeEscapedJsonContent(w, rt) catch continue;
                if (self.isNilableMethod(name)) w.writeAll(" | nil") catch continue;
            }
        }
        w.writeAll("\\n\\n\\u2192 ") catch continue;
        const rel = preRenderRelPath(sym_path, self.root_path);
        writeEscapedJsonContent(w, rel) catch continue;
        w.print(":{d}", .{@as(i64, @intCast(hs.line))}) catch continue;
        if (hs.doc) |d| {
            if (d.len > 0) {
                w.writeAll("\\n\\n") catch continue;
                writeEscapedJsonContent(w, d) catch continue;
            }
        }

        // Copy body + name into the HotIndex arena so they survive until next
        // rebuild. The Allocating writer's slice is owned by self.alloc; we
        // dupe into the arena and let aw.deinit free the temp.
        const body_owned = arena.dupe(u8, aw.written()) catch continue;
        const name_owned = arena.dupe(u8, name) catch continue;
        hot.putPreRendered(name_owned, body_owned) catch continue;
        rendered += 1;
    }

    var lbuf: [128]u8 = undefined;
    const lmsg = std.fmt.bufPrint(&lbuf, "refract: hover pre-rendered {d} top symbols", .{rendered}) catch "refract: hover pre-rendered";
    self.sendLogMessage(3, lmsg);
}

fn preRenderRelPath(sym_path: []const u8, root_path: ?[]u8) []const u8 {
    const rp = root_path orelse return sym_path;
    if (!std.mem.startsWith(u8, sym_path, rp)) return sym_path;
    const after = sym_path[rp.len..];
    return if (after.len > 0 and after[0] == '/') after[1..] else after;
}

/// Pre-render goto-definition response bodies for the top-N hot symbols.
/// Stores two variants per name:
///   - LocationLink fragment (LSP 3.14+) sans braces and origin: caller wraps
///     with `{...,"originSelectionRange":{...}}` per request.
///   - Legacy Location (full object including braces): emit verbatim.
/// Skipped on multi-def names (rendering would be ambiguous).
fn preRenderHotDef(self: *Server, hot: *hot_index_mod.HotIndex) !void {
    const arena = hot.arena.allocator();
    var frc: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var it = frc.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        frc.deinit(self.alloc);
    }

    // Iterate every unambiguous def-like name in the hot index, not just the
    // top-N most-referenced. Covers the long tail of micro-bench probe
    // positions for free — file I/O for UTF-16 columns is amortized by `frc`.
    var rendered: u32 = 0;
    var nm_it = hot.name_map.iterator();
    while (nm_it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len == 0) continue;
        const syms = entry.value_ptr.*;
        if (syms.len == 0) continue;

        var picked: ?hot_index_mod.HotSymbol = null;
        var def_count: u32 = 0;
        for (syms) |s| {
            if (s.kind != .def and s.kind != .classdef and s.kind != .class_ and s.kind != .module) continue;
            // Mirror the go-to-def exclusion: a routing-DSL `def` synthesized in a
            // Rails routes file is not a real method definition (it lives in the
            // routes table). Pre-rendering it here would bypass the resolver's
            // filter for unambiguous names and wrong-jump `recv.<name>`.
            if (s.kind == .def) {
                const sp = hot.pathFor(s.file_id) orelse continue;
                if (navigation.isRailsRoutesFile(sp)) continue;
            }
            picked = s;
            def_count += 1;
        }
        if (def_count != 1) continue;
        const hs = picked.?;
        const sym_path = hot.pathFor(hs.file_id) orelse continue;

        const sym_line0 = @as(i64, @intCast(hs.line)) - 1;
        const start_char = self.toClientColFromPath(&frc, sym_path, sym_line0, @intCast(hs.col));
        const end_char = start_char + @as(u32, @intCast(name.len));

        // LocationLink fragment (no outer braces, no origin).
        var aw_link = std.Io.Writer.Allocating.init(self.alloc);
        defer aw_link.deinit();
        const w_link = &aw_link.writer;
        w_link.writeAll("\"targetUri\":\"file://") catch continue;
        writePathAsUri(w_link, sym_path) catch continue;
        w_link.print("\",\"targetRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
            sym_line0, start_char, sym_line0, end_char,
        }) catch continue;
        w_link.print(",\"targetSelectionRange\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{
            sym_line0, start_char, sym_line0, end_char,
        }) catch continue;
        const link_owned = arena.dupe(u8, aw_link.written()) catch continue;

        // Legacy Location (full self-contained object).
        var aw_loc = std.Io.Writer.Allocating.init(self.alloc);
        defer aw_loc.deinit();
        const w_loc = &aw_loc.writer;
        w_loc.writeAll("{\"uri\":\"file://") catch continue;
        writePathAsUri(w_loc, sym_path) catch continue;
        w_loc.print("\",\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}}}", .{
            sym_line0, start_char, sym_line0, end_char,
        }) catch continue;
        const loc_owned = arena.dupe(u8, aw_loc.written()) catch continue;

        const name_owned = arena.dupe(u8, name) catch continue;
        hot.putPreDefLink(name_owned, link_owned) catch continue;
        hot.putPreDefLoc(name_owned, loc_owned) catch continue;
        rendered += 1;
    }

    var lbuf: [128]u8 = undefined;
    const lmsg = std.fmt.bufPrint(&lbuf, "refract: def pre-rendered {d} top symbols", .{rendered}) catch "refract: def pre-rendered";
    self.sendLogMessage(3, lmsg);
}

/// Pre-render the static portion of a completion item — everything from `{`
/// through `"documentation"`, with no `textEdit` and no closing `}`. Hot path
/// appends a compact `,"textEdit":{...}}` suffix per request. Only stored when
/// the name is unambiguous in `name_map` (single def/classdef/class/module/
/// constant) so the bake-in of kind/sig/doc is correct.
fn preRenderHotCompletion(self: *Server, hot: *hot_index_mod.HotIndex) !void {
    const arena = hot.arena.allocator();
    var rendered: u32 = 0;

    var nm_it = hot.name_map.iterator();
    while (nm_it.next()) |entry| {
        const syms = entry.value_ptr.*;
        if (syms.len != 1) continue;
        const sym = syms[0];
        if (sym.name.len == 0) continue;
        const kind_is_renderable = switch (sym.kind) {
            .def, .classdef, .class_, .module, .constant => true,
            else => false,
        };
        if (!kind_is_renderable) continue;

        const sig: []const u8 = sym.params_sig orelse "";
        const doc: []const u8 = sym.doc orelse "";
        const is_deprecated = std.mem.startsWith(u8, doc, "**Deprecated:**");
        const is_def_like = sym.kind == .def or sym.kind == .classdef;
        const kind_num: u8 = switch (sym.kind) {
            .class_ => 7,
            .module => 9,
            .def, .classdef => 3,
            .constant => 21,
            else => 1,
        };
        const kind_str: []const u8 = switch (sym.kind) {
            .def => "def",
            .classdef => "classdef",
            .class_ => "class",
            .module => "module",
            .constant => "constant",
            else => "other",
        };
        // Bake non-exact sort prefix (`0_1_` etc); exact-match path falls back
        // to dynamic render (rare in practice — user has typed a prefix, not
        // the full name).
        const sort_prefix: []const u8 = if (is_deprecated) "8_" else switch (sym.kind) {
            .def, .classdef => "0_1_",
            .class_, .module => "1_1_",
            else => "2_1_",
        };

        var aw = std.Io.Writer.Allocating.init(arena);
        defer aw.deinit();
        const w = &aw.writer;

        w.writeAll("{\"label\":") catch continue;
        writeEscapedJson(w, sym.name) catch continue;
        w.print(",\"kind\":{d},\"detail\":\"(", .{kind_num}) catch continue;
        if (is_def_like and sig.len > 0) {
            writeEscapedJsonContent(w, sig) catch continue;
        } else {
            writeEscapedJsonContent(w, kind_str) catch continue;
        }
        w.writeAll(")\",\"sortText\":\"") catch continue;
        writeEscapedJsonContent(w, sort_prefix) catch continue;
        writeEscapedJsonContent(w, sym.name) catch continue;
        w.writeAll("\",\"filterText\":\"") catch continue;
        writeEscapedJsonContent(w, sym.name) catch continue;
        w.writeByte('"') catch continue;
        if (is_def_like) {
            w.writeAll(",\"commitCharacters\":[\"(\"]") catch continue;
        }
        if (is_def_like and sig.len > 0) {
            completion.writeInsertTextSnippet(w, sym.name, sig) catch continue;
        }
        if (doc.len > 0) {
            w.writeAll(",\"documentation\":{\"kind\":\"markdown\",\"value\":") catch continue;
            writeEscapedJson(w, doc) catch continue;
            w.writeByte('}') catch continue;
        }

        const body_owned = arena.dupe(u8, aw.written()) catch continue;
        const name_owned = arena.dupe(u8, sym.name) catch continue;
        hot.putPreCompletion(name_owned, body_owned) catch continue;
        rendered += 1;
    }

    var lbuf: [128]u8 = undefined;
    const lmsg = std.fmt.bufPrint(&lbuf, "refract: completion pre-rendered {d} symbols", .{rendered}) catch "refract: completion pre-rendered";
    self.sendLogMessage(3, lmsg);
}
