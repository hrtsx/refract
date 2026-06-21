const std = @import("std");
const db_mod = @import("../db.zig");
const prism = @import("../prism.zig");
const erb_mapping = @import("../lsp/erb_mapping.zig");
const index = @import("index.zig");

pub fn getDiags(path: []const u8, alloc: std.mem.Allocator) ![]index.DiagEntry {
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        std.Options.debug_io,
        path,
        alloc,
        std.Io.Limit.limited(8 * 1024 * 1024),
        .@"1",
        0,
    ) catch return &.{};
    defer alloc.free(source);

    if (source.len == 0) return &.{};

    var erb_buf: ?[]u8 = null;
    defer if (erb_buf) |b| alloc.free(b);
    const prism_src: []const u8 = if (std.mem.endsWith(u8, path, ".erb")) blk: {
        erb_buf = try extractErbRuby(alloc, source);
        break :blk erb_buf.?;
    } else if (std.mem.endsWith(u8, path, ".haml")) blk: {
        erb_buf = try extractHamlRuby(alloc, source);
        break :blk erb_buf.?;
    } else if (std.mem.endsWith(u8, path, ".slim")) blk: {
        erb_buf = try extractSlimRuby(alloc, source);
        break :blk erb_buf.?;
    } else source;

    var arena = prism.Arena{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, prism_src.ptr, prism_src.len - 1, null);
    defer prism.parser_free(&parser);
    _ = prism.parse(&parser);

    var list = std.ArrayList(index.DiagEntry).empty;
    errdefer {
        for (list.items) |e| alloc.free(e.message);
        list.deinit(alloc);
    }

    var node = parser.error_list.head;
    while (node != null) {
        const diag: *const prism.Diagnostic = @ptrCast(@alignCast(node));
        const msg_slice = std.mem.span(diag.message);
        const lc = index.locationLineCol(&parser, diag.location.start);
        try list.append(alloc, .{
            .line = lc.line,
            .col = lc.col,
            .message = try alloc.dupe(u8, msg_slice),
        });
        node = diag.node.next;
    }

    return list.toOwnedSlice(alloc);
}

pub fn getDiagsFromSource(source: []const u8, path: []const u8, alloc: std.mem.Allocator) ![]index.DiagEntry {
    if (source.len == 0) return &.{};

    var erb_buf: ?[]u8 = null;
    defer if (erb_buf) |b| alloc.free(b);
    const prism_src: []const u8 = if (std.mem.endsWith(u8, path, ".erb")) blk: {
        erb_buf = try extractErbRuby(alloc, source);
        break :blk erb_buf.?;
    } else if (std.mem.endsWith(u8, path, ".haml")) blk: {
        erb_buf = try extractHamlRuby(alloc, source);
        break :blk erb_buf.?;
    } else if (std.mem.endsWith(u8, path, ".slim")) blk: {
        erb_buf = try extractSlimRuby(alloc, source);
        break :blk erb_buf.?;
    } else source;

    var arena = prism.Arena{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, prism_src.ptr, prism_src.len, null);
    defer prism.parser_free(&parser);
    _ = prism.parse(&parser);

    var list = std.ArrayList(index.DiagEntry).empty;
    errdefer {
        for (list.items) |e| alloc.free(e.message);
        list.deinit(alloc);
    }

    var node = parser.error_list.head;
    while (node != null) {
        const diag: *const prism.Diagnostic = @ptrCast(@alignCast(node));
        const msg_slice = std.mem.span(diag.message);
        const lc = index.locationLineCol(&parser, diag.location.start);
        try list.append(alloc, .{
            .line = lc.line,
            .col = lc.col,
            .message = try alloc.dupe(u8, msg_slice),
        });
        node = diag.node.next;
    }

    return list.toOwnedSlice(alloc);
}

pub fn extractErbRuby(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var buf = try alloc.dupe(u8, source);
    var i: usize = 0;
    var in_ruby = false;
    var is_comment = false;

    while (i < source.len) {
        if (!in_ruby) {
            if (i + 1 < source.len and source[i] == '<' and source[i + 1] == '%') {
                if (i + 2 < source.len and source[i + 2] == '%') {
                    buf[i] = ' ';
                    buf[i + 1] = ' ';
                    buf[i + 2] = ' ';
                    i += 3;
                    continue;
                }
                buf[i] = ' ';
                buf[i + 1] = ' ';
                i += 2;
                if (i < source.len) switch (source[i]) {
                    '#' => {
                        is_comment = true;
                        buf[i] = ' ';
                        i += 1;
                    },
                    '=', '-' => {
                        buf[i] = ' ';
                        i += 1;
                    },
                    else => {},
                };
                in_ruby = true;
                continue;
            }
            if (source[i] != '\n') buf[i] = ' ';
            i += 1;
        } else {
            if (i + 1 < source.len and source[i] == '%' and source[i + 1] == '>') {
                buf[i] = ' ';
                buf[i + 1] = ' ';
                i += 2;
                if (i < source.len and source[i] == '-') {
                    buf[i] = ' ';
                    i += 1;
                }
                in_ruby = false;
                is_comment = false;
                continue;
            }
            if (is_comment and source[i] != '\n') buf[i] = ' ';
            i += 1;
        }
    }
    return buf;
}

pub fn extractHamlRuby(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var map = try erb_mapping.buildHamlMap(alloc, source);
    defer map.deinit();

    var buf = try alloc.alloc(u8, source.len);
    @memset(buf, ' ');

    for (map.spans) |span| {
        if (span.ruby_end > buf.len or span.erb_end > source.len) continue;
        const ruby_len = span.ruby_end - span.ruby_start;
        if (span.ruby_start + ruby_len > buf.len or span.erb_start + ruby_len > source.len) continue;
        @memcpy(buf[span.ruby_start..][0..ruby_len], source[span.erb_start..][0..ruby_len]);
    }

    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == ' ' and source[i] == '\n') {
            buf[i] = '\n';
        }
    }

    return buf;
}

pub fn extractSlimRuby(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var map = try erb_mapping.buildSlimMap(alloc, source);
    defer map.deinit();

    var buf = try alloc.alloc(u8, source.len);
    @memset(buf, ' ');

    for (map.spans) |span| {
        if (span.ruby_end > buf.len or span.erb_end > source.len) continue;
        const ruby_len = span.ruby_end - span.ruby_start;
        if (span.ruby_start + ruby_len > buf.len or span.erb_start + ruby_len > source.len) continue;
        @memcpy(buf[span.ruby_start..][0..ruby_len], source[span.erb_start..][0..ruby_len]);
    }

    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == ' ' and source[i] == '\n') {
            buf[i] = '\n';
        }
    }

    return buf;
}

pub fn runSemanticChecks(db: db_mod.Db, file_id: i64, alloc: std.mem.Allocator) !std.ArrayList(index.DiagEntry) {
    var diags = std.ArrayList(index.DiagEntry).empty;

    // Unused local variable detection: local_vars not referenced in refs within same file
    // Skip names starting with _ (convention for intentionally unused)
    const unused_stmt = db.prepare(
        \\SELECT lv.name, lv.line, lv.col FROM local_vars lv
        \\WHERE lv.file_id = ? AND lv.name NOT LIKE '\_%' ESCAPE '\'
        \\AND lv.name NOT LIKE '@%' AND lv.name NOT LIKE '$%'
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM refs r WHERE r.file_id = lv.file_id AND r.name = lv.name
        \\)
    ) catch return diags;
    defer unused_stmt.finalize();
    unused_stmt.bind_int(1, file_id);

    while (unused_stmt.step() catch false) {
        const var_name = unused_stmt.column_text(0);
        const line = unused_stmt.column_int(1);
        const col = unused_stmt.column_int(2);

        const msg = std.fmt.allocPrint(alloc, "unused local variable '{s}'", .{var_name}) catch continue;
        diags.append(alloc, .{
            .line = @intCast(line),
            .col = @intCast(col),
            .message = msg,
            .severity = 2,
            .code = "refract/unused-variable",
        }) catch {
            alloc.free(msg);
        };
    }

    const param_stmt = db.prepare(
        \\SELECT p.name, s.line, s.col FROM params p
        \\JOIN symbols s ON p.symbol_id = s.id
        \\WHERE s.file_id = ? AND s.kind = 'def'
        \\AND p.name NOT LIKE '\_%' ESCAPE '\'
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM refs r WHERE r.file_id = s.file_id AND r.name = p.name
        \\)
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM local_vars lv WHERE lv.file_id = s.file_id AND lv.name = p.name
        \\)
    ) catch return diags;
    defer param_stmt.finalize();
    param_stmt.bind_int(1, file_id);

    while (param_stmt.step() catch false) {
        const pname = param_stmt.column_text(0);
        const pline = param_stmt.column_int(1);
        const pcol = param_stmt.column_int(2);
        const pmsg = std.fmt.allocPrint(alloc, "unused parameter '{s}'", .{pname}) catch continue;
        diags.append(alloc, .{
            .line = @intCast(pline),
            .col = @intCast(pcol),
            .message = pmsg,
            .severity = 4,
            .code = "refract/unused-parameter",
        }) catch {
            alloc.free(pmsg);
        };
    }

    const method_stmt = db.prepare(
        \\SELECT s.name, s.line, s.col FROM symbols s
        \\WHERE s.file_id = ? AND s.kind = 'def'
        \\AND s.visibility = 'public'
        \\AND s.name NOT LIKE '\_%' ESCAPE '\'
        \\AND s.name NOT IN (
        \\  'initialize','to_s','inspect','to_h','to_a','to_i','to_f','to_str',
        \\  'to_proc','to_ary','to_hash','to_int','to_io','to_path','to_regexp',
        \\  'method_missing','respond_to_missing?','inherited','included',
        \\  'extended','prepended','const_missing','hash','eql?','<=>','==',
        \\  'coerce','encode_with','init_with','marshal_dump','marshal_load'
        \\)
        \\AND s.name NOT LIKE 'test\_%' ESCAPE '\'
        \\AND s.name NOT IN ('setup','teardown','before','after')
        \\AND NOT EXISTS (SELECT 1 FROM refs r WHERE r.name = s.name)
    ) catch return diags;
    defer method_stmt.finalize();
    method_stmt.bind_int(1, file_id);

    while (method_stmt.step() catch false) {
        const mname = method_stmt.column_text(0);
        const mline = method_stmt.column_int(1);
        const mcol = method_stmt.column_int(2);
        const mmsg = std.fmt.allocPrint(alloc, "unused method '{s}'", .{mname}) catch continue;
        diags.append(alloc, .{
            .line = @intCast(mline),
            .col = @intCast(mcol),
            .message = mmsg,
            .severity = 4,
            .code = "refract/unused-method",
        }) catch {
            alloc.free(mmsg);
        };
    }

    // Synthesized DSL methods are recorded as defs tagged with their generator in
    // `doc` (e.g. `delegate :m` → doc='delegate'; `before(:each)` → a symbol named
    // 'each' with doc='before'). These are not hand-written definitions, so a
    // collision with a real method — or two RSpec `before(:each)` hooks — is not a
    // real "defined multiple times". Exclude generator-tagged defs from both sides.
    const dup_stmt = db.prepare(
        \\SELECT s1.name, s1.line FROM symbols s1
        \\WHERE s1.file_id = ? AND s1.kind = 'def'
        \\AND COALESCE(s1.doc,'') NOT IN ('delegate','before','after','around')
        \\AND EXISTS (
        \\  SELECT 1 FROM symbols s2
        \\  WHERE s2.file_id = s1.file_id AND s2.name = s1.name AND s2.kind = 'def'
        \\  AND s2.id != s1.id
        \\  AND COALESCE(s2.parent_name,'') = COALESCE(s1.parent_name,'')
        \\  AND COALESCE(s2.doc,'') NOT IN ('delegate','before','after','around')
        \\)
        \\ORDER BY s1.name, s1.line
    ) catch return diags;
    defer dup_stmt.finalize();
    dup_stmt.bind_int(1, file_id);

    while (dup_stmt.step() catch false) {
        const dname = dup_stmt.column_text(0);
        const dline = dup_stmt.column_int(1);
        const dmsg = std.fmt.allocPrint(alloc, "method '{s}' defined multiple times", .{dname}) catch continue;
        diags.append(alloc, .{
            .line = @intCast(dline),
            .col = 0,
            .message = dmsg,
            .severity = 2,
            .code = "refract/duplicate-method",
        }) catch {
            alloc.free(dmsg);
        };
    }

    // Undefined method with fuzzy "did you mean?" suggestions.
    //
    // Strategy, in order of cheapness:
    //   1. Filter refs already defined as workspace symbols or local vars (SQL).
    //   2. Skip Ruby/Rails/RSpec built-in method names via the static allowlists.
    //   3. For each surviving ref, locate its enclosing class/module and walk the
    //      ancestor chain (superclass + mixins). If any ancestor lives outside the
    //      index (e.g. ActiveRecord::Base), bail out silently — we cannot prove the
    //      method is undefined without knowing what those externals provide.
    //   4. Only flag when the entire ancestor chain is fully visible in the symbols
    //      table and the method is provably absent from every link.
    // A file is "dynamic" when it defines method_missing / respond_to_missing? or uses
    // metaprogramming (define_method, send, *_eval, …). Such files can answer calls we
    // cannot see statically, so we suppress the suggestion-less undefined-method path.
    var file_has_dynamic = false;
    {
        const dyn_stmt = db.prepare(
            \\SELECT
            \\  EXISTS(SELECT 1 FROM symbols WHERE file_id = ? AND kind = 'def'
            \\    AND name IN ('method_missing','respond_to_missing?','method_added','const_missing'))
            \\  OR EXISTS(SELECT 1 FROM refs WHERE file_id = ?
            \\    AND name IN ('define_method','define_singleton_method','instance_eval','class_eval',
            \\      'module_eval','instance_exec','class_exec','send','__send__','public_send','method_missing',
            \\      'let','let!','subject','it','describe','context','specify','shared_examples','shared_context'))
        ) catch return diags;
        defer dyn_stmt.finalize();
        dyn_stmt.bind_int(1, file_id);
        dyn_stmt.bind_int(2, file_id);
        if (dyn_stmt.step() catch false) file_has_dynamic = dyn_stmt.column_int(0) != 0;
    }

    const ref_stmt = db.prepare(
        \\SELECT r.name, r.line, r.col, r.kind FROM refs r
        \\WHERE r.file_id = ? AND r.name NOT LIKE '\_%' ESCAPE '\'
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM symbols s WHERE s.name = r.name
        \\)
        \\AND NOT EXISTS (
        \\  SELECT 1 FROM local_vars lv WHERE lv.file_id = r.file_id AND lv.name = r.name
        \\)
    ) catch return diags;
    defer ref_stmt.finalize();
    ref_stmt.bind_int(1, file_id);

    while (ref_stmt.step() catch false) {
        const ref_name = ref_stmt.column_text(0);
        const line = ref_stmt.column_int(1);
        const col = ref_stmt.column_int(2);
        const ref_kind = ref_stmt.column_text(3);
        const is_self_send = std.mem.eql(u8, ref_kind, "self_call");

        // Skip common Ruby built-ins and keywords
        if (ref_name.len == 0) continue;
        if (ref_name[0] >= 'A' and ref_name[0] <= 'Z') continue; // constants handled elsewhere
        if (index.isBuiltinMethod(ref_name)) continue;
        if (index.isRailsDsl(ref_name)) continue;
        if (index.isIterationMethod(ref_name)) continue;
        if (index.isSorbetDsl(ref_name)) continue;

        // Ancestry-aware check. Find the innermost class/module that contains this
        // ref's line and resolve the method against its full ancestor chain.
        var enc_is_module = false;
        if (index.findEnclosingClass(db, file_id, line, alloc)) |enc| {
            defer alloc.free(enc.name);
            enc_is_module = enc.is_module;
            const resolution = index.resolveMethodInAncestors(db, enc.name, ref_name, alloc);
            switch (resolution) {
                .found => continue, // method actually exists somewhere in the chain
                .unknown => continue, // external ancestor — cannot prove absent
                .not_found => {}, // fall through to fuzzy suggestion + diagnostic
            }
        } else {
            // Top-level ref with no enclosing class. Without receiver context we
            // cannot reliably distinguish a typo from a method in Kernel / loaded
            // scripts, so skip rather than noise.
            continue;
        }

        // Find similar symbol names for "did you mean?" suggestions
        const similar = db.prepare(
            \\SELECT DISTINCT name FROM symbols
            \\WHERE kind IN ('def','classdef') AND name LIKE ? ESCAPE '\'
            \\LIMIT 10
        ) catch continue;
        defer similar.finalize();
        var like_buf: [256]u8 = undefined;
        const like_pat = std.fmt.bufPrint(&like_buf, "%{s}%", .{ref_name}) catch continue;
        similar.bind_text(1, like_pat);

        // `candidate` is a column_text slice into SQLite's row buffer, invalidated by
        // the next step(). Copy the current best into a stable buffer so the slice we
        // format later is not a use-after-free (which printed garbage bytes).
        var best_buf: [128]u8 = undefined;
        var best_len: usize = 0;
        var has_best = false;
        // Tighter threshold: at most 2 edits, and never more than half the ref length
        const max_dist: u32 = @min(@as(u32, 2), @as(u32, @intCast(ref_name.len / 2 + 1)));
        var best_dist: u32 = max_dist + 1;
        while (similar.step() catch false) {
            const candidate = similar.column_text(0);
            // Reject operator-name candidates (==, <=>, <<, []=, etc.) — they are never sensible
            // suggestions for an identifier typo.
            if (candidate.len == 0) continue;
            const first = candidate[0];
            const is_ident_start = (first >= 'a' and first <= 'z') or first == '_';
            if (!is_ident_start) continue;
            if (candidate.len > best_buf.len) continue;
            const dist = index.editDistance(ref_name, candidate);
            if (dist > 0 and dist < best_dist) {
                best_dist = dist;
                @memcpy(best_buf[0..candidate.len], candidate);
                best_len = candidate.len;
                has_best = true;
            }
        }

        if (has_best and !file_has_dynamic and !enc_is_module) {
            // Even a close-name suggestion is unsafe in a dynamic file (send/eval/
            // method_missing, or an RSpec example group whose let/subject helpers and
            // block params are not statically visible) or inside a mixed-in module —
            // these produced FPs on real code (block params, RSpec `let(:sl)`).
            const suggested = best_buf[0..best_len];
            const msg = std.fmt.allocPrint(alloc, "undefined method '{s}' \u{2014} did you mean '{s}'?", .{ ref_name, suggested }) catch continue;
            diags.append(alloc, .{
                .line = @intCast(line),
                .col = @intCast(col),
                .message = msg,
                .severity = 2,
                .code = "refract/undefined-method",
            }) catch {
                alloc.free(msg);
            };
        } else if (is_self_send and !file_has_dynamic and !enc_is_module) {
            // No close suggestion, but a receiverless call provably absent from the fully
            // visible ancestry of a non-dynamic class. Conservative: self-sends only, and
            // never inside a bare `module` — module bodies are mixed into unknown hosts at
            // runtime (Rails concerns / ActiveSupport::Concern), so a receiverless call is
            // very often a host- or sibling-concern-provided method, not a typo.
            const msg = std.fmt.allocPrint(alloc, "undefined method '{s}'", .{ref_name}) catch continue;
            diags.append(alloc, .{
                .line = @intCast(line),
                .col = @intCast(col),
                .message = msg,
                .severity = 2,
                .code = "refract/undefined-method",
            }) catch {
                alloc.free(msg);
            };
        }
    }

    // Type-checker: method called on a NilClass-narrowed receiver.
    // The narrower at insertLocalVar marks a var as NilClass when a control-flow guard
    // proves nil; we emit a warning every time such a var is the receiver of a call.
    {
        const nil_stmt = db.prepare(
            \\SELECT r.name, r.line, r.col FROM refs r
            \\WHERE r.file_id = ? AND r.receiver_type = 'NilClass'
        ) catch return diags;
        defer nil_stmt.finalize();
        nil_stmt.bind_int(1, file_id);
        while (nil_stmt.step() catch false) {
            const rname = nil_stmt.column_text(0);
            const rline = nil_stmt.column_int(1);
            const rcol = nil_stmt.column_int(2);
            const msg = std.fmt.allocPrint(alloc, "method '{s}' called on a value proven to be nil", .{rname}) catch continue;
            diags.append(alloc, .{
                .line = @intCast(rline),
                .col = @intCast(rcol),
                .message = msg,
                .severity = 2,
                .code = "refract/nil-receiver",
            }) catch alloc.free(msg);
        }
    }

    // Type-checker: too many positional arguments for a known method.
    //
    // Triggers only when:
    //   - the call site has a known receiver_type (confidence >= 70 at insertion),
    //   - that receiver has exactly one matching def in our index,
    //   - that def has no rest / keyword_rest / block param (which would accept any extras),
    //   - the call's arg_count exceeds the positional+keyword count.
    //
    // We deliberately use COALESCE on parent_name so non-namespaced top-level methods
    // also match when receiver_type matches their owning class.
    {
        const arity_stmt = db.prepare(
            \\SELECT r.name, r.line, r.col, r.arg_count, r.receiver_type FROM refs r
            \\WHERE r.file_id = ?
            \\  AND r.arg_count > 0
            \\  AND r.receiver_type IS NOT NULL
            \\  AND r.receiver_type != 'NilClass'
        ) catch return diags;
        defer arity_stmt.finalize();
        arity_stmt.bind_int(1, file_id);

        while (arity_stmt.step() catch false) {
            const rname = arity_stmt.column_text(0);
            const rline = arity_stmt.column_int(1);
            const rcol = arity_stmt.column_int(2);
            const rargs = arity_stmt.column_int(3);
            const rtype = arity_stmt.column_text(4);
            if (rtype.len == 0) continue;

            // Find the matching method definition's id.
            const sym_stmt = db.prepare(
                \\SELECT id FROM symbols
                \\WHERE name = ? AND COALESCE(parent_name,'') = ? AND kind IN ('def','classdef')
                \\LIMIT 2
            ) catch continue;
            defer sym_stmt.finalize();
            sym_stmt.bind_text(1, rname);
            sym_stmt.bind_text(2, rtype);
            if (!(sym_stmt.step() catch false)) continue;
            const sym_id = sym_stmt.column_int(0);
            // If multiple defs match (e.g. monkey patches), bail to avoid false positives.
            if (sym_stmt.step() catch false) continue;

            // Sum non-variadic params and check for variadic kinds.
            const arity_param_stmt = db.prepare(
                \\SELECT
                \\  SUM(CASE WHEN kind IN ('rest','keyword_rest','block') THEN 1 ELSE 0 END) AS variadic,
                \\  SUM(CASE WHEN kind NOT IN ('rest','keyword_rest','block') OR kind IS NULL THEN 1 ELSE 0 END) AS fixed
                \\FROM params WHERE symbol_id = ?
            ) catch continue;
            defer arity_param_stmt.finalize();
            arity_param_stmt.bind_int(1, sym_id);
            if (!(arity_param_stmt.step() catch false)) continue;
            const variadic = arity_param_stmt.column_int(0);
            const fixed = arity_param_stmt.column_int(1);
            if (variadic > 0) continue; // accepts any number of extras
            if (fixed == 0) continue; // method has no params recorded — likely incomplete index

            if (rargs > fixed) {
                const msg = std.fmt.allocPrint(alloc, "too many arguments for '{s}': got {d}, expected at most {d}", .{ rname, rargs, fixed }) catch continue;
                diags.append(alloc, .{
                    .line = @intCast(rline),
                    .col = @intCast(rcol),
                    .message = msg,
                    .severity = 2,
                    .code = "refract/wrong-arity",
                }) catch alloc.free(msg);
            }
        }
    }

    // Type-checker: arity on receiverless self-sends (e.g. `triple(1, 2)` inside a class).
    //
    // The block above needs a known receiver_type and only flags too-many. Self-sends store
    // a null receiver_type but carry kind='self_call' (recorded at insertCallRef). Here we
    // resolve the callee against the *enclosing* class and flag both too-many and too-few.
    //
    // Conservative gates mirror the receiver-typed path:
    //   - exactly one matching def on the enclosing class (bail on monkey-patch ambiguity),
    //   - too-many only when the def has no variadic param (rest/keyword_rest/block),
    //   - too-few only when the def takes no keyword params (a trailing hash could supply them).
    {
        const self_stmt = db.prepare(
            \\SELECT r.name, r.line, r.col, r.arg_count FROM refs r
            \\WHERE r.file_id = ? AND r.kind = 'self_call' AND r.arg_count > 0
        ) catch return diags;
        defer self_stmt.finalize();
        self_stmt.bind_int(1, file_id);

        while (self_stmt.step() catch false) {
            const rname = self_stmt.column_text(0);
            const rline = self_stmt.column_int(1);
            const rcol = self_stmt.column_int(2);
            const rargs = self_stmt.column_int(3);
            if (rname.len == 0) continue;
            if (index.isBuiltinMethod(rname)) continue;
            if (index.isRailsDsl(rname)) continue;
            if (index.isIterationMethod(rname)) continue;

            const enc = index.findEnclosingClass(db, file_id, rline, alloc) orelse continue;
            defer alloc.free(enc.name);

            // Resolve the callee to exactly one def directly on the enclosing class.
            const sym_stmt = db.prepare(
                \\SELECT id FROM symbols
                \\WHERE name = ? AND COALESCE(parent_name,'') = ? AND kind IN ('def','classdef')
                \\LIMIT 2
            ) catch continue;
            defer sym_stmt.finalize();
            sym_stmt.bind_text(1, rname);
            sym_stmt.bind_text(2, enc.name);
            if (!(sym_stmt.step() catch false)) continue;
            const sym_id = sym_stmt.column_int(0);
            if (sym_stmt.step() catch false) continue; // ambiguous — bail

            const self_param_stmt = db.prepare(
                \\SELECT
                \\  SUM(CASE WHEN kind = 'required' THEN 1 ELSE 0 END) AS req,
                \\  SUM(CASE WHEN kind IN ('keyword','keyword_rest') THEN 1 ELSE 0 END) AS kw,
                \\  SUM(CASE WHEN kind IN ('rest','keyword_rest','block') THEN 1 ELSE 0 END) AS variadic,
                \\  SUM(CASE WHEN kind NOT IN ('rest','keyword_rest','block') OR kind IS NULL THEN 1 ELSE 0 END) AS fixed
                \\FROM params WHERE symbol_id = ?
            ) catch continue;
            defer self_param_stmt.finalize();
            self_param_stmt.bind_int(1, sym_id);
            if (!(self_param_stmt.step() catch false)) continue;
            const req = self_param_stmt.column_int(0);
            const kw = self_param_stmt.column_int(1);
            const variadic = self_param_stmt.column_int(2);
            const fixed = self_param_stmt.column_int(3);

            if (variadic == 0 and rargs > fixed) {
                const msg = std.fmt.allocPrint(alloc, "too many arguments for '{s}': got {d}, expected at most {d}", .{ rname, rargs, fixed }) catch continue;
                diags.append(alloc, .{
                    .line = @intCast(rline),
                    .col = @intCast(rcol),
                    .message = msg,
                    .severity = 2,
                    .code = "refract/wrong-arity",
                }) catch alloc.free(msg);
            } else if (kw == 0 and rargs < req) {
                const msg = std.fmt.allocPrint(alloc, "too few arguments for '{s}': got {d}, expected {d}", .{ rname, rargs, req }) catch continue;
                diags.append(alloc, .{
                    .line = @intCast(rline),
                    .col = @intCast(rcol),
                    .message = msg,
                    .severity = 2,
                    .code = "refract/wrong-arity",
                }) catch alloc.free(msg);
            }
        }
    }

    return diags;
}
