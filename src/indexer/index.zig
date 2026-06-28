const std = @import("std");
const db_mod = @import("../db.zig");
const prism = @import("../prism.zig");
const i18n_mod = @import("i18n.zig");
const routes_mod = @import("routes.zig");
const erb_mapping = @import("../lsp/erb_mapping.zig");
const stdlib_types = @import("stdlib_types.zig");
const rbs_parser = @import("rbs_parser.zig");
const resolve_mod = @import("resolution.zig");
const semantic = @import("semantic.zig");
const rails_dsl = @import("rails_dsl.zig");
const type_inference = @import("type_inference.zig");
pub const runFlowTypingPass = @import("flow_typing_pass.zig").runFlowTypingPass;
const prism_util = @import("prism_util.zig");

pub const LogSink = *const fn (ctx: ?*anyopaque, level: u8, msg: []const u8) void;
pub var log_sink: ?LogSink = null;
pub var log_sink_ctx: ?*anyopaque = null;

var reindex_stat_error_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var commitparsed_prepare_error_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var commitparsed_step_error_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var indexsource_cleanup_error_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn emitLog(level: u8, msg: []const u8) void {
    if (log_sink) |sink| {
        sink(log_sink_ctx, level, msg);
    } else {
        std.debug.print("{s}", .{msg});
        std.debug.print("{s}", .{"\n"});
    }
}

fn logRateLimited(site: []const u8, err: anyerror, relpath: []const u8, counter: *std.atomic.Value(u32)) void {
    const count = counter.fetchAdd(1, .monotonic);
    if (count < 5) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "refract index: {s}: {}: {s}", .{ site, err, relpath }) catch return;
        emitLog(3, msg);
    } else if (count == 1023) {
        var buf: [512]u8 = undefined;
        const suppressed = count - 4;
        const msg = std.fmt.bufPrint(&buf, "refract index: {s}: ({} suppressed)", .{ site, suppressed }) catch return;
        emitLog(3, msg);
    }
}

const visit_ctx = @import("visit_ctx.zig");
const SemToken = visit_ctx.SemToken;
pub const VisitCtx = visit_ctx.VisitCtx;

pub const resolveConstant = prism_util.resolveConstant;

pub const locationLineCol = prism_util.locationLineCol;

const addSemToken = visit_ctx.addSemToken;
const symbol_insert = @import("symbol_insert.zig");
pub const insertSymbol = symbol_insert.insertSymbol;
pub const insertSymbolWithReturn = symbol_insert.insertSymbolWithReturn;
const insertSymbolGetId = symbol_insert.insertSymbolGetId;
const insertRef = symbol_insert.insertRef;
const insertCallRef = symbol_insert.insertCallRef;
pub const insertParam = symbol_insert.insertParam;
pub const insertLocalVar = symbol_insert.insertLocalVar;
const insertLocalVarClassId = symbol_insert.insertLocalVarClassId;
const insertMixin = symbol_insert.insertMixin;
pub const namespaceFromStack = symbol_insert.namespaceFromStack;

const type_hints = @import("type_hints.zig");
const updateSymbolReturnType = type_hints.updateSymbolReturnType;
const extractTypeAnnotation = type_hints.extractTypeAnnotation;
const extractNewCallType = type_hints.extractNewCallType;
const inferReceiverType = type_hints.inferReceiverType;
const lookupMethodReturn = type_hints.lookupMethodReturn;
const detectTypeGuard = type_hints.detectTypeGuard;
const detectNilGuard = type_hints.detectNilGuard;
const extractSorbetSig = type_hints.extractSorbetSig;
const findLastSorbetSig = type_hints.findLastSorbetSig;
const findCallArgs = type_hints.findCallArgs;
const parseSorbetParams = type_hints.parseSorbetParams;

const visitor_dispatch = @import("visitor_dispatch.zig");
const visitor = visitor_dispatch.visitor;

pub const inferLiteralType = type_inference.inferLiteralType;
pub const normalizeRbsReturn = type_inference.normalizeRbsReturn;
pub const parseYardReturn = type_inference.parseYardReturn;
pub const parseYardParam = type_inference.parseYardParam;
pub const parseYardParamDesc = type_inference.parseYardParamDesc;
pub const extractDocComment = type_inference.extractDocComment;

/// Grouping/label DSLs whose argument is a LABEL, not a method name (Rails routing
/// `namespace`/`resource`/`resources`, Rake `task`, FactoryBot/Fabrication
/// `sequence` — a named generator reached via `generate(:x)`, never `recv.x`).
/// Their argument is indexed for workspace-symbol/outline under the non-goto
/// `namespace` kind so it never shadows a real method in identifier go-to-def.
/// `scope` is deliberately NOT here — AR `scope :active` IS a callable method.
pub fn isScopeLabelDsl(name: []const u8) bool {
    return std.mem.eql(u8, name, "namespace") or
        std.mem.eql(u8, name, "resource") or
        std.mem.eql(u8, name, "resources") or
        std.mem.eql(u8, name, "task") or
        std.mem.eql(u8, name, "sequence");
}

pub const inferBlockReturnType = rails_dsl.inferBlockReturnType;
pub const insertAttachedSymbols = rails_dsl.insertAttachedSymbols;
pub const insertAttrSymbols = rails_dsl.insertAttrSymbols;
pub const insertAttributeSymbol = rails_dsl.insertAttributeSymbol;
pub const insertBlockParams = rails_dsl.insertBlockParams;
pub const insertComposedOfSymbols = rails_dsl.insertComposedOfSymbols;
pub const insertDelegatedTypeSymbols = rails_dsl.insertDelegatedTypeSymbols;
pub const insertEnumSymbols = rails_dsl.insertEnumSymbols;
pub const insertNestedAttributesSymbols = rails_dsl.insertNestedAttributesSymbols;
pub const insertRailsDslSymbols = rails_dsl.insertRailsDslSymbols;
pub const insertRichTextSymbols = rails_dsl.insertRichTextSymbols;
pub const insertSecurePasswordSymbols = rails_dsl.insertSecurePasswordSymbols;
pub const insertSecureTokenSymbols = rails_dsl.insertSecureTokenSymbols;
pub const insertStoreAccessorSymbols = rails_dsl.insertStoreAccessorSymbols;
pub const isBuiltinMethod = rails_dsl.isBuiltinMethod;
pub const isIterationMethod = rails_dsl.isIterationMethod;
pub const isRailsDsl = rails_dsl.isRailsDsl;
pub const isSorbetDsl = rails_dsl.isSorbetDsl;
pub const schemaColumnType = rails_dsl.schemaColumnType;
pub const stripArrayBrackets = rails_dsl.stripArrayBrackets;
pub const tableNameToModel = rails_dsl.tableNameToModel;

pub fn editDistance(a: []const u8, b: []const u8) u32 {
    if (a.len > 64 or b.len > 64) return 99;
    if (a.len == 0) return @intCast(b.len);
    if (b.len == 0) return @intCast(a.len);
    var prev: [65]u32 = undefined;
    var curr: [65]u32 = undefined;
    for (0..b.len + 1) |j| prev[j] = @intCast(j);
    for (a, 0..) |ca, i| {
        curr[0] = @intCast(i + 1);
        for (b, 0..) |cb, j| {
            const cost: u32 = if (ca == cb) 0 else 1;
            curr[j + 1] = @min(@min(curr[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

pub const isRbsIdent = rbs_parser.isRbsIdent;
pub const indexRbs = rbs_parser.indexRbs;

fn storeSemTokens(db: db_mod.Db, file_id: i64, tokens: []const SemToken, alloc: std.mem.Allocator) !void {
    if (tokens.len == 0) {
        const del = try db.prepare("DELETE FROM sem_tokens WHERE file_id = ?");
        defer del.finalize();
        del.bind_int(1, file_id);
        _ = try del.step();
        return;
    }

    // Sort by (line, col)
    const sorted = try alloc.dupe(SemToken, tokens);
    defer alloc.free(sorted);
    std.sort.block(SemToken, sorted, {}, struct {
        fn lt(_: void, a: SemToken, b: SemToken) bool {
            if (a.line != b.line) return a.line < b.line;
            return a.col < b.col;
        }
    }.lt);

    // Delta-encode into u32 array
    const blob = try alloc.alloc(u32, sorted.len * 5);
    defer alloc.free(blob);

    var prev_line: u32 = 0;
    var prev_col: u32 = 0;
    for (sorted, 0..) |tok, i| {
        const lsp_line = tok.line - 1; // convert to 0-based
        const delta_line = lsp_line - prev_line;
        const delta_col = if (delta_line == 0) tok.col - prev_col else tok.col;
        blob[i * 5 + 0] = delta_line;
        blob[i * 5 + 1] = delta_col;
        blob[i * 5 + 2] = tok.len;
        blob[i * 5 + 3] = tok.token_type;
        blob[i * 5 + 4] = tok.mods;
        prev_line = lsp_line;
        prev_col = tok.col;
    }

    // Pack as LE bytes
    const bytes = try alloc.alloc(u8, blob.len * 4);
    defer alloc.free(bytes);
    for (blob, 0..) |v, i| {
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], v, .little);
    }

    const stmt = try db.prepare(
        \\INSERT INTO sem_tokens (file_id, prev_blob, blob)
        \\VALUES (?, (SELECT blob FROM sem_tokens WHERE file_id=?), ?)
        \\ON CONFLICT(file_id) DO UPDATE SET
        \\  prev_blob=excluded.prev_blob, blob=excluded.blob
    );
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_int(2, file_id);
    stmt.bind_blob(3, bytes);
    _ = try stmt.step();
}

pub const DiagEntry = struct {
    line: i32,
    col: u32,
    message: []u8,
    severity: u8 = 1,
    source: []const u8 = "refract",
    end_col: u32 = 0,
    code: []const u8 = "",
};

pub const lookupStdlibReturn = stdlib_types.lookupStdlibReturn;

pub const findEnclosingClass = resolve_mod.findEnclosingClass;
pub const resolveMethodInAncestors = resolve_mod.resolveMethodInAncestors;
pub const resolveConstantNested = resolve_mod.resolveConstantNested;
pub const resolveRefsForFile = resolve_mod.resolveRefsForFile;

pub const getDiags = semantic.getDiags;
pub const getDiagsFromSource = semantic.getDiagsFromSource;
pub const runSemanticChecks = semantic.runSemanticChecks;
pub const extractErbRuby = semantic.extractErbRuby;
pub const extractHamlRuby = semantic.extractHamlRuby;
pub const extractSlimRuby = semantic.extractSlimRuby;

/// Optional progress callback for long-running reindex operations.
/// Called every PROGRESS_STRIDE files with (done, total, last_path).
/// Safe to call while the DB transaction is open — must not touch the DB.
pub const ProgressCallback = struct {
    ctx: *anyopaque,
    report: *const fn (ctx: *anyopaque, done: usize, total: usize, path: []const u8) void,
};

const PROGRESS_STRIDE = 25;

pub fn reindex(db: db_mod.Db, paths: []const []const u8, is_gem: bool, alloc: std.mem.Allocator, max_file_size: usize, progress: ?ProgressCallback) !void {
    // Chunked commit strategy: a single transaction over 10k+ files makes the
    // WAL grow to hundreds of MB and the final COMMIT becomes pathological.
    // Committing every CHUNK_SIZE files lets the WAL auto-checkpoint (PRAGMA
    // wal_autocheckpoint=100 pages) and keeps memory + write throughput steady.
    // Refs are keyed by name, not symbol_id, so cross-chunk lookups still work.
    const CHUNK_SIZE: usize = 500;

    var in_tx = false;
    defer if (in_tx) {
        db.rollback() catch {}; // rollback best-effort if we never reached the final commit
    };

    // file_ids re-parsed this run; their refs get def_id resolved in a post-pass once
    // every file is committed (cross-file resolution needs the full symbol table).
    var touched = std.ArrayList(i64).empty;
    defer touched.deinit(alloc);

    for (paths, 0..) |path, i| {
        if (i % CHUNK_SIZE == 0) {
            if (in_tx) {
                try db.commit();
                in_tx = false;
            }
            try db.begin();
            in_tx = true;
        }
        // Fire progress every PROGRESS_STRIDE files (and on the final file)
        if (progress) |cb| {
            if (i % PROGRESS_STRIDE == 0 or i + 1 == paths.len) {
                cb.report(cb.ctx, i + 1, paths.len, path);
            }
        }
        // Check mtime; fast-skip unchanged files
        const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch |err| {
            logRateLimited("stat", err, path, &reindex_stat_error_count);
            continue;
        };
        const disk_mtime: i64 = stat.mtime.toMilliseconds();

        const check = try db.prepare("SELECT mtime, content_hash FROM files WHERE path = ?");
        defer check.finalize();
        check.bind_text(1, path);
        const has_existing = try check.step();
        var db_mtime: i64 = -1;
        var db_hash: i64 = 0;
        if (has_existing) {
            db_mtime = check.column_int(0);
            db_hash = check.column_int(1);
        }

        // Evict files that now exceed the configured limit, regardless of mtime.
        // This handles the case where maxFileSize was tightened via didChangeConfiguration
        // while the file on disk is unchanged.
        if (stat.size > max_file_size) {
            if (has_existing) {
                if (db.prepare("DELETE FROM files WHERE path = ?")) |del_stmt| {
                    defer del_stmt.finalize();
                    del_stmt.bind_text(1, path);
                    _ = del_stmt.step() catch {};
                } else |_| {}
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "refract: evicting {s} (exceeds maxFileSize)", .{path}) catch "refract: evicting file (too large)";
                emitLog(3, msg);
            }
            continue;
        }

        if (has_existing and db_mtime == disk_mtime and db_hash != 0) continue;

        const source = std.Io.Dir.cwd().readFileAllocOptions(
            std.Options.debug_io,
            path,
            alloc,
            std.Io.Limit.limited(max_file_size),
            .@"1",
            0,
        ) catch |err| {
            if (err == error.StreamTooLong) {
                var buf: [512]u8 = undefined;
                const msg = if (max_file_size == 8 * 1024 * 1024)
                    std.fmt.bufPrint(&buf, "refract: skipping {s} (>8MB)", .{path}) catch "refract: skipping file (too large)"
                else
                    std.fmt.bufPrint(&buf, "refract: skipping {s} (file too large)", .{path}) catch "refract: skipping file (too large)";
                emitLog(3, msg);
                if (has_existing) {
                    if (db.prepare("DELETE FROM files WHERE path = ?")) |del_stmt| {
                        defer del_stmt.finalize();
                        del_stmt.bind_text(1, path);
                        _ = del_stmt.step() catch {};
                    } else |_| {}
                }
            }
            continue;
        };
        defer alloc.free(source);

        if (source.len == 0) continue;

        // Compute content hash; skip if content is unchanged despite mtime change
        const content_hash: i64 = @bitCast(std.hash.Wyhash.hash(0, source[0 .. source.len - 1]));
        if (has_existing and db_hash == content_hash and content_hash != 0) continue;

        // Upsert file record with mtime, content_hash, and is_gem flag
        const upsert = try db.prepare(
            \\INSERT INTO files (path, mtime, content_hash, is_gem) VALUES (?, ?, ?, ?)
            \\ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, content_hash=excluded.content_hash, is_gem=excluded.is_gem
            \\RETURNING id
        );
        defer upsert.finalize();
        upsert.bind_text(1, path);
        upsert.bind_int(2, disk_mtime);
        upsert.bind_int(3, content_hash);
        upsert.bind_int(4, if (is_gem) 1 else 0);
        const has_row = try upsert.step();
        const file_id: i64 = if (has_row) upsert.column_int(0) else db.last_insert_rowid();

        // Delete domain-specific tables (these have their own re-indexing below)
        if (db.prepare("DELETE FROM i18n_keys WHERE file_id = ?")) |s| {
            defer s.finalize();
            s.bind_int(1, file_id);
            _ = s.step() catch {}; // cleanup
        } else |_| {}
        if (db.prepare("DELETE FROM routes WHERE file_id = ?")) |s| {
            defer s.finalize();
            s.bind_int(1, file_id);
            _ = s.step() catch {}; // cleanup
        } else |_| {}

        // Routes: index config/routes*.rb, routes/*.rb, and common Sinatra entry points
        const is_route_file = (std.mem.containsAtLeast(u8, path, 1, "config/routes") or
            std.mem.containsAtLeast(u8, path, 1, "routes/") or
            std.mem.endsWith(u8, path, "/app.rb") or
            std.mem.endsWith(u8, path, "/web.rb") or
            std.mem.endsWith(u8, path, "/server.rb"));
        if (is_route_file and std.mem.endsWith(u8, path, ".rb")) {
            routes_mod.indexRoutesWithPath(db, file_id, source[0 .. source.len - 1], alloc, path);
        }

        // RBS: parse type signatures directly, skip Prism
        if (std.mem.endsWith(u8, path, ".rbs")) {
            deleteSymbolData(db, file_id);
            try indexRbs(db, file_id, source[0 .. source.len - 1]);
            continue;
        }

        if (std.mem.endsWith(u8, path, ".yml") or std.mem.endsWith(u8, path, ".yaml")) {
            if (std.mem.containsAtLeast(u8, path, 1, "locales/")) {
                i18n_mod.indexLocaleFile(db, file_id, source[0 .. source.len - 1]);
            }
            // Skip non-locale YAML files — Prism can hang on large YAML parsed as Ruby
            continue;
        }

        const parse_source: []const u8 = if (std.mem.endsWith(u8, path, ".erb")) blk: {
            const extracted = try extractErbRuby(alloc, source[0 .. source.len - 1]);
            break :blk extracted;
        } else if (std.mem.endsWith(u8, path, ".haml")) blk: {
            const extracted = try extractHamlRuby(alloc, source[0 .. source.len - 1]);
            break :blk extracted;
        } else if (std.mem.endsWith(u8, path, ".slim")) blk: {
            const extracted = try extractSlimRuby(alloc, source[0 .. source.len - 1]);
            break :blk extracted;
        } else source[0 .. source.len - 1];
        defer if (std.mem.endsWith(u8, path, ".erb") or std.mem.endsWith(u8, path, ".haml") or std.mem.endsWith(u8, path, ".slim")) alloc.free(parse_source);

        // Parse AST first — if parse fails, preserve existing index
        var arena = prism.Arena{ .current = null, .block_count = 0 };
        defer prism.arena_free(&arena);
        var parser: prism.Parser = undefined;
        prism.parser_init(&arena, &parser, parse_source.ptr, parse_source.len, null);
        defer prism.parser_free(&parser);

        const root = prism.parse(&parser);
        if (root == null) continue;

        // Parse succeeded — now safe to delete old symbols/refs/local_vars
        deleteSymbolData(db, file_id);

        var ctx = VisitCtx{
            .db = db,
            .file_id = file_id,
            .parser = &parser,
            .alloc = alloc,
            .sem_tokens = std.ArrayList(SemToken).empty,
            .source = parse_source,
            .is_rbi = std.mem.indexOf(u8, path, "sorbet/rbi/") != null,
        };
        defer ctx.sem_tokens.deinit(alloc);

        prism.visit_node(root, visitor, &ctx);

        if (ctx.error_count > 0) {
            var ebuf: [256]u8 = undefined;
            const emsg = std.fmt.bufPrint(&ebuf, "refract: {d} index error(s) in {s} (DB full or schema mismatch?)", .{ ctx.error_count, path }) catch "refract: index errors occurred";
            emitLog(2, emsg);
        }

        storeSemTokens(db, file_id, ctx.sem_tokens.items, alloc) catch {}; // non-critical: highlighting only
        touched.append(alloc, file_id) catch {};
    }

    if (in_tx) {
        try db.commit();
        in_tx = false;
    }

    // Resolve refs.def_id for the workspace files touched this run. Gem refs are not
    // linked (never edited/queried for references). Shared memo avoids re-walking
    // common ancestries across files.
    if (!is_gem and touched.items.len > 0) {
        var memo = std.StringHashMap(i64).init(alloc);
        defer {
            var it = memo.keyIterator();
            while (it.next()) |k| alloc.free(k.*);
            memo.deinit();
        }
        db.begin() catch return;
        for (touched.items) |fid| resolveRefsForFile(db, fid, alloc, &memo);
        db.commit() catch db.rollback() catch {};
    }
}

fn deleteSymbolData(db: db_mod.Db, file_id: i64) void {
    if (db.prepare("DELETE FROM symbols WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch {};
    } else |_| {}
    if (db.prepare("DELETE FROM refs WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch {};
    } else |_| {}
    if (db.prepare("DELETE FROM local_vars WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch {};
    } else |_| {}
}

pub fn shouldSkip(db: db_mod.Db, path: []const u8, disk_mtime: i64) bool {
    const stmt = db.prepare("SELECT mtime, content_hash FROM files WHERE path = ?") catch return false;
    defer stmt.finalize();
    stmt.bind_text(1, path);
    const has_row = stmt.step() catch return false;
    if (!has_row) return false;
    const db_mtime = stmt.column_int(0);
    const db_hash = stmt.column_int(1);
    return db_mtime == disk_mtime and db_hash != 0;
}

pub fn commitParsed(real_db: db_mod.Db, mem_db: db_mod.Db, path: []const u8, is_gem: bool, alloc: std.mem.Allocator) !void {
    // Query the mem_db for parse results
    const fq = mem_db.prepare("SELECT id, mtime, content_hash FROM files WHERE path = ?") catch |err| {
        logRateLimited("commitParsed_prepare", err, path, &commitparsed_prepare_error_count);
        return;
    };
    defer fq.finalize();
    fq.bind_text(1, path);
    const stepped = fq.step() catch |err| {
        logRateLimited("commitParsed_step", err, path, &commitparsed_step_error_count);
        return;
    };
    if (!stepped) return;
    const mem_file_id = fq.column_int(0);
    const disk_mtime = fq.column_int(1);
    const content_hash = fq.column_int(2);

    // Skip if content unchanged in real_db
    const ck = real_db.prepare("SELECT content_hash FROM files WHERE path = ?") catch return;
    defer ck.finalize();
    ck.bind_text(1, path);
    if (ck.step() catch false) {
        if (ck.column_int(0) == content_hash and content_hash != 0) return;
    }

    try real_db.begin();
    var committed = false;
    defer if (!committed) {
        real_db.rollback() catch {};
    }; // rollback best-effort

    // Upsert file record in real_db
    const upsert = try real_db.prepare(
        \\INSERT INTO files (path, mtime, content_hash, is_gem) VALUES (?, ?, ?, ?)
        \\ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, content_hash=excluded.content_hash, is_gem=excluded.is_gem
        \\RETURNING id
    );
    defer upsert.finalize();
    upsert.bind_text(1, path);
    upsert.bind_int(2, disk_mtime);
    upsert.bind_int(3, content_hash);
    upsert.bind_int(4, if (is_gem) 1 else 0);
    const has_file_row = try upsert.step();
    const real_file_id: i64 = if (has_file_row) upsert.column_int(0) else real_db.last_insert_rowid();
    // Reset the RETURNING cursor: a stepped-but-unreset statement leaves SQL "in
    // progress", which makes the final COMMIT fail with "cannot commit transaction
    // - SQL statements in progress" — silently dropping every cold-indexed file.
    upsert.reset();

    // Delete old symbols (cascades to params and mixins via FK)
    const del_sym = try real_db.prepare("DELETE FROM symbols WHERE file_id = ?");
    defer del_sym.finalize();
    del_sym.bind_int(1, real_file_id);
    _ = try del_sym.step();

    const del_refs = try real_db.prepare("DELETE FROM refs WHERE file_id = ?");
    defer del_refs.finalize();
    del_refs.bind_int(1, real_file_id);
    _ = try del_refs.step();

    const del_lv = try real_db.prepare("DELETE FROM local_vars WHERE file_id = ?");
    defer del_lv.finalize();
    del_lv.bind_int(1, real_file_id);
    _ = try del_lv.step();

    const del_pr = try real_db.prepare("DELETE FROM pending_recv_returns WHERE file_id = ?");
    defer del_pr.finalize();
    del_pr.bind_int(1, real_file_id);
    _ = try del_pr.step();

    // Domain tables (routes, i18n) are generated per-file in mem_db too; clear the
    // real_db copies for this file before re-inserting so a re-index doesn't leave
    // stale rows.
    const del_rt = try real_db.prepare("DELETE FROM routes WHERE file_id = ?");
    defer del_rt.finalize();
    del_rt.bind_int(1, real_file_id);
    _ = try del_rt.step();

    const del_i18n = try real_db.prepare("DELETE FROM i18n_keys WHERE file_id = ?");
    defer del_i18n.finalize();
    del_i18n.bind_int(1, real_file_id);
    _ = try del_i18n.step();

    // Copy symbols from mem_db, building provisional→real ID map
    var id_map = std.AutoHashMap(i64, i64).init(alloc);
    defer id_map.deinit();

    const sel_sym = try mem_db.prepare(
        \\SELECT id, name, kind, line, col, return_type, doc, end_line, visibility, parent_name, value_snippet, superclass, deprecated
        \\FROM symbols WHERE file_id = ? ORDER BY id
    );
    defer sel_sym.finalize();
    sel_sym.bind_int(1, mem_file_id);

    const ins_sym = try real_db.prepare(
        \\INSERT INTO symbols (file_id, name, kind, line, col, return_type, doc, end_line, visibility, parent_name, value_snippet, superclass, deprecated)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id
    );
    defer ins_sym.finalize();

    while (try sel_sym.step()) {
        const mem_sym_id = sel_sym.column_int(0);
        ins_sym.reset();
        ins_sym.bind_int(1, real_file_id);
        ins_sym.bind_text(2, sel_sym.column_text(1));
        ins_sym.bind_text(3, sel_sym.column_text(2));
        ins_sym.bind_int(4, sel_sym.column_int(3));
        ins_sym.bind_int(5, sel_sym.column_int(4));
        const rt = sel_sym.column_text(5);
        if (rt.len > 0) ins_sym.bind_text(6, rt) else ins_sym.bind_null(6);
        const doc = sel_sym.column_text(6);
        if (doc.len > 0) ins_sym.bind_text(7, doc) else ins_sym.bind_null(7);
        if (sel_sym.column_type(7) != 5) ins_sym.bind_int(8, sel_sym.column_int(7)) else ins_sym.bind_null(8);
        ins_sym.bind_text(9, sel_sym.column_text(8));
        const pn = sel_sym.column_text(9);
        if (pn.len > 0) ins_sym.bind_text(10, pn) else ins_sym.bind_null(10);
        const vs = sel_sym.column_text(10);
        if (vs.len > 0) ins_sym.bind_text(11, vs) else ins_sym.bind_null(11);
        const sc = sel_sym.column_text(11);
        if (sc.len > 0) ins_sym.bind_text(12, sc) else ins_sym.bind_null(12);
        ins_sym.bind_int(13, sel_sym.column_int(12));
        const got_row = try ins_sym.step();
        const real_sym_id: i64 = if (got_row) ins_sym.column_int(0) else real_db.last_insert_rowid();
        ins_sym.reset();
        try id_map.put(mem_sym_id, real_sym_id);
    }

    // Copy params
    const sel_p = try mem_db.prepare(
        \\SELECT p.symbol_id, p.position, p.name, p.kind, p.type_hint, p.confidence
        \\FROM params p JOIN symbols s ON p.symbol_id = s.id WHERE s.file_id = ?
    );
    defer sel_p.finalize();
    sel_p.bind_int(1, mem_file_id);

    const ins_p = try real_db.prepare(
        \\INSERT OR IGNORE INTO params (symbol_id, position, name, kind, type_hint, confidence)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer ins_p.finalize();

    while (try sel_p.step()) {
        const real_sym_id = id_map.get(sel_p.column_int(0)) orelse continue;
        ins_p.reset();
        ins_p.bind_int(1, real_sym_id);
        ins_p.bind_int(2, sel_p.column_int(1));
        ins_p.bind_text(3, sel_p.column_text(2));
        ins_p.bind_text(4, sel_p.column_text(3));
        const th = sel_p.column_text(4);
        if (th.len > 0) ins_p.bind_text(5, th) else ins_p.bind_null(5);
        ins_p.bind_int(6, sel_p.column_int(5));
        _ = try ins_p.step();
    }

    // Copy refs — including arg_count / receiver_type / ref_ns, which the binding
    // resolver (resolveRefsForFile) needs to link a method/constant ref to a single
    // definition. Dropping them here left every parallel-cold-indexed ref name-global.
    const sel_r = try mem_db.prepare(
        \\SELECT name, line, col, scope_id, kind, arg_count, receiver_type, ref_ns FROM refs WHERE file_id = ?
    );
    defer sel_r.finalize();
    sel_r.bind_int(1, mem_file_id);

    const ins_r = try real_db.prepare(
        \\INSERT OR IGNORE INTO refs (file_id, name, line, col, scope_id, kind, arg_count, receiver_type, ref_ns)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer ins_r.finalize();

    while (try sel_r.step()) {
        ins_r.reset();
        ins_r.bind_int(1, real_file_id);
        ins_r.bind_text(2, sel_r.column_text(0));
        ins_r.bind_int(3, sel_r.column_int(1));
        ins_r.bind_int(4, sel_r.column_int(2));
        if (sel_r.column_type(3) != 5) {
            const real_scope = id_map.get(sel_r.column_int(3)) orelse 0;
            if (real_scope != 0) ins_r.bind_int(5, real_scope) else ins_r.bind_null(5);
        } else ins_r.bind_null(5);
        if (sel_r.column_type(4) != 5) {
            ins_r.bind_text(6, sel_r.column_text(4));
        } else ins_r.bind_null(6);
        ins_r.bind_int(7, sel_r.column_int(5));
        if (sel_r.column_type(6) != 5) ins_r.bind_text(8, sel_r.column_text(6)) else ins_r.bind_null(8);
        if (sel_r.column_type(7) != 5) ins_r.bind_text(9, sel_r.column_text(7)) else ins_r.bind_null(9);
        _ = try ins_r.step();
    }

    // Copy local_vars
    const sel_lv = try mem_db.prepare(
        \\SELECT name, line, col, type_hint, confidence, scope_id, class_id FROM local_vars WHERE file_id = ?
    );
    defer sel_lv.finalize();
    sel_lv.bind_int(1, mem_file_id);

    const ins_lv = try real_db.prepare(
        \\INSERT OR IGNORE INTO local_vars (file_id, name, line, col, type_hint, confidence, scope_id, class_id)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer ins_lv.finalize();

    while (try sel_lv.step()) {
        ins_lv.reset();
        ins_lv.bind_int(1, real_file_id);
        ins_lv.bind_text(2, sel_lv.column_text(0));
        ins_lv.bind_int(3, sel_lv.column_int(1));
        ins_lv.bind_int(4, sel_lv.column_int(2));
        const th = sel_lv.column_text(3);
        if (th.len > 0) ins_lv.bind_text(5, th) else ins_lv.bind_null(5);
        ins_lv.bind_int(6, sel_lv.column_int(4));
        if (sel_lv.column_type(5) != 5) {
            const real_scope = id_map.get(sel_lv.column_int(5)) orelse 0;
            if (real_scope != 0) ins_lv.bind_int(7, real_scope) else ins_lv.bind_null(7);
        } else ins_lv.bind_null(7);
        if (sel_lv.column_type(6) != 5) {
            const real_class = id_map.get(sel_lv.column_int(6)) orelse 0;
            if (real_class != 0) ins_lv.bind_int(8, real_class) else ins_lv.bind_null(8);
        } else ins_lv.bind_null(8);
        _ = try ins_lv.step();
    }

    // Copy mixins (class_id references symbols, cascades on delete)
    const sel_mx = try mem_db.prepare(
        \\SELECT m.class_id, m.module_name, m.kind
        \\FROM mixins m JOIN symbols s ON m.class_id = s.id WHERE s.file_id = ?
    );
    defer sel_mx.finalize();
    sel_mx.bind_int(1, mem_file_id);

    const ins_mx = try real_db.prepare(
        \\INSERT INTO mixins (class_id, module_name, kind) VALUES (?, ?, ?)
    );
    defer ins_mx.finalize();

    while (try sel_mx.step()) {
        const real_class_id = id_map.get(sel_mx.column_int(0)) orelse continue;
        ins_mx.reset();
        ins_mx.bind_int(1, real_class_id);
        ins_mx.bind_text(2, sel_mx.column_text(1));
        ins_mx.bind_text(3, sel_mx.column_text(2));
        _ = try ins_mx.step();
    }

    // Copy pending_recv_returns (deferred `@ivar = recv.method` shapes; class_id references
    // symbols, remapped via id_map). The post-index flow-typing pass consumes these.
    const sel_pr = try mem_db.prepare(
        \\SELECT class_id, ivar_name, line, col, recv_kind, recv_name, method_name
        \\FROM pending_recv_returns WHERE file_id = ?
    );
    defer sel_pr.finalize();
    sel_pr.bind_int(1, mem_file_id);

    const ins_pr = try real_db.prepare(
        \\INSERT INTO pending_recv_returns (file_id, class_id, ivar_name, line, col, recv_kind, recv_name, method_name)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer ins_pr.finalize();

    while (try sel_pr.step()) {
        ins_pr.reset();
        ins_pr.bind_int(1, real_file_id);
        if (sel_pr.column_type(0) != 5) {
            const real_class = id_map.get(sel_pr.column_int(0)) orelse 0;
            if (real_class != 0) ins_pr.bind_int(2, real_class) else ins_pr.bind_null(2);
        } else ins_pr.bind_null(2);
        ins_pr.bind_text(3, sel_pr.column_text(1));
        ins_pr.bind_int(4, sel_pr.column_int(2));
        ins_pr.bind_int(5, sel_pr.column_int(3));
        ins_pr.bind_text(6, sel_pr.column_text(4));
        const rn = sel_pr.column_text(5);
        if (rn.len > 0) ins_pr.bind_text(7, rn) else ins_pr.bind_null(7);
        ins_pr.bind_text(8, sel_pr.column_text(6));
        _ = try ins_pr.step();
    }

    // Copy sem_tokens
    const sel_st = try mem_db.prepare("SELECT blob, prev_blob FROM sem_tokens WHERE file_id = ?");
    defer sel_st.finalize();
    sel_st.bind_int(1, mem_file_id);

    if (try sel_st.step()) {
        const ins_st = try real_db.prepare(
            \\INSERT OR REPLACE INTO sem_tokens (file_id, blob, prev_blob) VALUES (?, ?, ?)
        );
        defer ins_st.finalize();
        ins_st.bind_int(1, real_file_id);
        ins_st.bind_blob(2, sel_st.column_blob(0));
        const pb = sel_st.column_blob(1);
        if (pb.len > 0) ins_st.bind_blob(3, pb) else ins_st.bind_null(3);
        _ = try ins_st.step();
    }

    // Copy routes (Rails/Sinatra route maps) — without this, the bg cold-index
    // never persists route helpers for unopened files, so go-to-def on a route
    // helper fails on any file the editor hasn't opened.
    const sel_rt = try mem_db.prepare(
        \\SELECT http_method, path_pattern, helper_name, controller, action, line, col
        \\FROM routes WHERE file_id = ?
    );
    defer sel_rt.finalize();
    sel_rt.bind_int(1, mem_file_id);

    const ins_rt = try real_db.prepare(
        \\INSERT OR IGNORE INTO routes (file_id, http_method, path_pattern, helper_name, controller, action, line, col)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer ins_rt.finalize();

    while (try sel_rt.step()) {
        ins_rt.reset();
        ins_rt.bind_int(1, real_file_id);
        ins_rt.bind_text(2, sel_rt.column_text(0));
        ins_rt.bind_text(3, sel_rt.column_text(1));
        const hn = sel_rt.column_text(2);
        if (hn.len > 0) ins_rt.bind_text(4, hn) else ins_rt.bind_null(4);
        const ctrl = sel_rt.column_text(3);
        if (ctrl.len > 0) ins_rt.bind_text(5, ctrl) else ins_rt.bind_null(5);
        const act = sel_rt.column_text(4);
        if (act.len > 0) ins_rt.bind_text(6, act) else ins_rt.bind_null(6);
        ins_rt.bind_int(7, sel_rt.column_int(5));
        ins_rt.bind_int(8, sel_rt.column_int(6));
        _ = try ins_rt.step();
    }

    // Copy i18n_keys
    const sel_i18n = try mem_db.prepare("SELECT key, value, locale FROM i18n_keys WHERE file_id = ?");
    defer sel_i18n.finalize();
    sel_i18n.bind_int(1, mem_file_id);

    const ins_i18n = try real_db.prepare(
        \\INSERT OR IGNORE INTO i18n_keys (file_id, key, value, locale) VALUES (?, ?, ?, ?)
    );
    defer ins_i18n.finalize();

    while (try sel_i18n.step()) {
        ins_i18n.reset();
        ins_i18n.bind_int(1, real_file_id);
        ins_i18n.bind_text(2, sel_i18n.column_text(0));
        const v = sel_i18n.column_text(1);
        if (v.len > 0) ins_i18n.bind_text(3, v) else ins_i18n.bind_null(3);
        const loc = sel_i18n.column_text(2);
        if (loc.len > 0) ins_i18n.bind_text(4, loc) else ins_i18n.bind_null(4);
        _ = try ins_i18n.step();
    }

    try real_db.commit();
    committed = true;
}

pub fn indexSource(source: []const u8, path: []const u8, db: db_mod.Db, alloc: std.mem.Allocator) !void {
    var src = source;
    if (src.len >= 3 and src[0] == 0xEF and src[1] == 0xBB and src[2] == 0xBF) {
        src = src[3..];
    }
    if (!std.unicode.utf8ValidateSlice(src)) return;
    if (src.len == 0) return;

    // Upsert file record — zero mtime and content_hash so reindex always re-reads disk next time
    const upsert = try db.prepare(
        \\INSERT INTO files (path, mtime, content_hash, is_gem) VALUES (?, 0, 0, 0)
        \\ON CONFLICT(path) DO UPDATE SET mtime=0, content_hash=0
        \\RETURNING id
    );
    defer upsert.finalize();
    upsert.bind_text(1, path);
    const has_row = try upsert.step();
    const file_id: i64 = if (has_row) upsert.column_int(0) else db.last_insert_rowid();

    // Delete old symbols, refs, and local_vars for this file
    const del = try db.prepare("DELETE FROM symbols WHERE file_id = ?");
    defer del.finalize();
    del.bind_int(1, file_id);
    _ = try del.step();

    const del_refs = try db.prepare("DELETE FROM refs WHERE file_id = ?");
    defer del_refs.finalize();
    del_refs.bind_int(1, file_id);
    _ = try del_refs.step();

    const del_lvars = try db.prepare("DELETE FROM local_vars WHERE file_id = ?");
    defer del_lvars.finalize();
    del_lvars.bind_int(1, file_id);
    _ = try del_lvars.step();

    if (db.prepare("DELETE FROM i18n_keys WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch |err| {
            logRateLimited("indexSource_i18n", err, path, &indexsource_cleanup_error_count);
        };
    } else |err| logRateLimited("indexSource_i18n_prepare", err, path, &indexsource_cleanup_error_count);
    if (db.prepare("DELETE FROM routes WHERE file_id = ?")) |s| {
        defer s.finalize();
        s.bind_int(1, file_id);
        _ = s.step() catch |err| {
            logRateLimited("indexSource_routes", err, path, &indexsource_cleanup_error_count);
        };
    } else |err| logRateLimited("indexSource_routes_prepare", err, path, &indexsource_cleanup_error_count);

    var arena = prism.Arena{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, src.ptr, src.len, null);
    defer prism.parser_free(&parser);

    const root = prism.parse(&parser);
    if (root == null) return;

    var ctx = VisitCtx{
        .db = db,
        .file_id = file_id,
        .parser = &parser,
        .alloc = alloc,
        .sem_tokens = std.ArrayList(SemToken).empty,
        .source = src,
        .is_rbi = std.mem.indexOf(u8, path, "sorbet/rbi/") != null,
    };
    defer ctx.sem_tokens.deinit(alloc);

    prism.visit_node(root, visitor, &ctx);

    storeSemTokens(db, file_id, ctx.sem_tokens.items, alloc) catch {}; // non-critical: highlighting only

    // Resolve this file's refs against the global symbol table (binding-scoped refs/rename).
    var memo = std.StringHashMap(i64).init(alloc);
    defer {
        var it = memo.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        memo.deinit();
    }
    resolveRefsForFile(db, file_id, alloc, &memo);
}

pub fn indexBundledRbs(db: db_mod.Db) !usize {
    const bundled_rbs = @import("bundled_rbs.zig");
    var count: usize = 0;
    for (bundled_rbs.files) |f| {
        if (f.content.len == 0) continue;
        const upsert = db.prepare(
            \\INSERT INTO files (path, mtime, content_hash, is_gem) VALUES (?, 0, 0, 1)
            \\ON CONFLICT(path) DO UPDATE SET mtime=0, content_hash=0, is_gem=1
            \\RETURNING id
        ) catch continue;
        defer upsert.finalize();
        upsert.bind_text(1, f.path);
        const has_row = upsert.step() catch continue;
        const file_id: i64 = if (has_row) upsert.column_int(0) else db.last_insert_rowid();

        deleteSymbolData(db, file_id);
        indexRbs(db, file_id, f.content) catch continue;
        count += 1;
    }
    return count;
}

pub fn ensureBundledRbs(db: db_mod.Db) void {
    const bundled_rbs = @import("bundled_rbs.zig");
    const expected: i64 = @intCast(bundled_rbs.files.len);
    const cnt_stmt = db.prepare("SELECT COUNT(*) FROM files WHERE path LIKE '<bundled>/%'") catch return;
    defer cnt_stmt.finalize();
    var current: i64 = 0;
    if (cnt_stmt.step() catch false) current = cnt_stmt.column_int(0);
    if (current >= expected) return;
    _ = indexBundledRbs(db) catch return;
}

pub fn cleanupStale(db: db_mod.Db, scanned: []const []const u8, root_path: []const u8, alloc: std.mem.Allocator, keep: ?*const std.StringHashMapUnmanaged(void)) !void {
    var disk_set = std.StringHashMap(void).init(alloc);
    defer disk_set.deinit();
    for (scanned) |p| try disk_set.put(p, {});

    // Only consider files under root_path so extra_roots are never wrongly deleted
    const like_pat = try std.fmt.allocPrint(alloc, "{s}/%", .{root_path});
    defer alloc.free(like_pat);
    const sel = try db.prepare("SELECT path FROM files WHERE is_gem=0 AND path LIKE ? ESCAPE '\\' AND path NOT LIKE '<bundled>/%'");
    defer sel.finalize();
    sel.bind_text(1, like_pat);
    var stale = std.ArrayList([]u8).empty;
    defer {
        for (stale.items) |p| alloc.free(p);
        stale.deinit(alloc);
    }
    while (try sel.step()) {
        const p = sel.column_text(0);
        if (disk_set.contains(p)) continue;
        if (keep) |k| if (k.contains(p)) continue;
        // Defensive: only stale if the file is actually gone from disk.
        // Guards against scan/FS-visibility races where a present file wasn't
        // in the initial scan set (e.g. macOS FSEvents lag).
        _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, p, .{}) catch {
            try stale.append(alloc, try alloc.dupe(u8, p));
            continue;
        };
    }

    if (stale.items.len == 0) return;

    try db.begin();
    var committed = false;
    defer if (!committed) {
        db.rollback() catch {}; // rollback best-effort
    };
    const del = try db.prepare("DELETE FROM files WHERE path = ?");
    defer del.finalize();
    for (stale.items) |p| {
        del.reset();
        del.bind_text(1, p);
        _ = try del.step();
    }
    try db.commit();
    committed = true;
}

test "cleanupStale preserves gem entries" {
    const alloc = std.testing.allocator;

    const db_path = "/tmp/refract_gem_cleanup_test.db";
    std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, db_path) catch {};
    const db = try db_mod.Db.open(db_path);
    defer db.close();
    defer std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, db_path) catch {};
    try db.init_schema();

    try db.exec("INSERT INTO files (path, mtime, is_gem) VALUES ('/gems/activesupport/core.rb', 999, 1)");

    const project_paths = [_][]const u8{"/tmp/project_file.rb"};
    try cleanupStale(db, &project_paths, "/tmp", alloc, null);

    const check = try db.prepare("SELECT COUNT(*) FROM files WHERE path='/gems/activesupport/core.rb' AND is_gem=1");
    defer check.finalize();
    try std.testing.expect(try check.step());
    try std.testing.expectEqual(@as(i64, 1), check.column_int(0));
}

test "go-to-def resolves a method defined in an indexed gem file" {
    // Hermetic proof that gem methods resolve: index a fake gem source on the
    // LOAD_PATH (mark it is_gem like real bundle indexing does), then assert the
    // method is found by the SAME query go-to-def runs (name + kind). No bundle
    // install / network — this is the durable evidence the bench can't produce.
    const alloc = std.testing.allocator;
    const db = try db_mod.Db.open(":memory:");
    defer db.close();
    try db.init_schema();

    const gem_path = "/gems/activesupport/lib/active_support/core_ext/enumerable.rb";
    try indexSource(
        \\module Enumerable
        \\  def compact_blank
        \\    reject(&:blank?)
        \\  end
        \\end
    , gem_path, db, alloc);
    try db.exec("UPDATE files SET is_gem=1 WHERE path='/gems/activesupport/lib/active_support/core_ext/enumerable.rb'");

    // Mirror navigation.zig's go-to-def lookup: by name + def-like kind.
    const s = try db.prepare(
        \\SELECT f.path FROM symbols sym JOIN files f ON sym.file_id = f.id
        \\WHERE sym.name = ? AND sym.kind IN ('def','classdef') AND f.is_gem = 1
    );
    defer s.finalize();
    s.bind_text(1, "compact_blank");
    try std.testing.expect(try s.step());
    try std.testing.expectEqualStrings(gem_path, s.column_text(0));
}

test "error logging with rate limiting" {
    const nonexistent_path = "/nonexistent/path/to/file.rb";
    const initial_count = reindex_stat_error_count.load(.monotonic);
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, nonexistent_path, .{}) catch |err| {
        logRateLimited("test_site", err, nonexistent_path, &reindex_stat_error_count);
    };
    const final_count = reindex_stat_error_count.load(.monotonic);
    try std.testing.expect(final_count > initial_count);
}
