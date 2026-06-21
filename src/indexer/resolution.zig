const std = @import("std");
const db_mod = @import("../db.zig");

// Find the innermost class/module symbol that textually contains the given line.
// Returns the symbol's id and fully qualified name, or null if the line is not inside any
// class/module body in this file.
pub fn findEnclosingClass(
    db: db_mod.Db,
    file_id: i64,
    line: i64,
    alloc: std.mem.Allocator,
) ?struct { id: i64, name: []u8, is_module: bool } {
    // Exclude synthesized FactoryBot factory/trait symbols: they are recorded with
    // kind 'class' (so go-to-def works) but a `factory :order do … end` block is NOT
    // a real lexical scope — treating it as the enclosing class made its DSL/transient
    // attributes look like undefined self-sends.
    const stmt = db.prepare(
        \\SELECT id, name, kind FROM symbols
        \\WHERE file_id = ? AND kind IN ('class','classdef','module','moduledef')
        \\  AND COALESCE(doc,'') NOT IN ('factory','trait')
        \\  AND line <= ?
        \\  AND (end_line IS NULL OR end_line >= ?)
        \\ORDER BY line DESC
        \\LIMIT 1
    ) catch return null;
    defer stmt.finalize();
    stmt.bind_int(1, file_id);
    stmt.bind_int(2, line);
    stmt.bind_int(3, line);
    if (!(stmt.step() catch false)) return null;
    const id = stmt.column_int(0);
    const name_text = stmt.column_text(1);
    const kind_text = stmt.column_text(2);
    const is_module = std.mem.eql(u8, kind_text, "module") or std.mem.eql(u8, kind_text, "moduledef");
    const owned = alloc.dupe(u8, name_text) catch return null;
    return .{ .id = id, .name = owned, .is_module = is_module };
}

const MethodResolution = enum {
    found, // method exists somewhere in the known ancestor chain
    not_found, // entire ancestor chain walked, fully known, no match
    unknown, // at least one ancestor is outside the index; cannot decide
};

// Walk the ancestor chain of `class_name` looking for a `def` whose name matches
// `method_name`. Returns:
//   .found       — exists on the class or any reachable ancestor
//   .not_found   — fully walked a known chain, method absent
//   .unknown     — an ancestor is not in the symbols table (external gem/stdlib)
//
// "Ancestor" here means: the class itself, its recorded parent_name (superclass when
// the class is top-level, namespace parent otherwise — a known limitation of the
// current schema), and every module in the `mixins` table attached to the class.
// Reopened Ruby core classes (`class Array … end`) have their real methods in the
// interpreter, not the index — their ancestry can never be proven closed, so a
// receiverless call inside one must not be flagged.
fn isBuiltinCoreClass(name: []const u8) bool {
    const core = [_][]const u8{
        "Array",    "Hash",      "String",      "Integer", "Float",      "Numeric",
        "Symbol",   "Range",     "Regexp",      "Proc",    "Method",     "Module",
        "Class",    "Object",    "BasicObject", "Kernel",  "Comparable", "Enumerable",
        "Struct",   "Set",       "Time",        "IO",      "File",       "Exception",
        "Thread",   "Mutex",     "Rational",    "Complex", "MatchData",  "Enumerator",
        "NilClass", "TrueClass", "FalseClass",
    };
    for (core) |c| if (std.mem.eql(u8, name, c)) return true;
    return false;
}

pub fn resolveMethodInAncestors(
    db: db_mod.Db,
    class_name: []const u8,
    method_name: []const u8,
    alloc: std.mem.Allocator,
) MethodResolution {
    var seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit();
    }
    var queue = std.ArrayList([]u8).empty;
    defer {
        for (queue.items) |item| alloc.free(item);
        queue.deinit(alloc);
    }

    const first = alloc.dupe(u8, class_name) catch return .unknown;
    queue.append(alloc, first) catch {
        alloc.free(first);
        return .unknown;
    };

    var steps: u32 = 0;
    const max_steps: u32 = 32;

    while (queue.items.len > 0) {
        if (steps >= max_steps) return .unknown;
        steps += 1;

        const name = queue.orderedRemove(0);
        defer alloc.free(name);

        // A reopened core class (or a core class in the ancestry) has interpreter-
        // provided methods we cannot see — cannot prove the method absent.
        if (isBuiltinCoreClass(name)) return .unknown;

        if (seen.contains(name)) continue;
        const key_copy = alloc.dupe(u8, name) catch return .unknown;
        seen.put(key_copy, {}) catch {
            alloc.free(key_copy);
            return .unknown;
        };

        // Look up the class/module symbol by name. If not present, the chain is
        // external — we cannot decide anything, bail out.
        const lookup = db.prepare(
            \\SELECT id, parent_name, superclass FROM symbols
            \\WHERE name = ? AND kind IN ('class','classdef','module','moduledef')
            \\LIMIT 1
        ) catch return .unknown;
        defer lookup.finalize();
        lookup.bind_text(1, name);
        if (!(lookup.step() catch false)) return .unknown;
        const class_id = lookup.column_int(0);
        const parent_name_slice = lookup.column_text(1);
        const superclass_dup: ?[]u8 = blk: {
            const sc = lookup.column_text(2);
            break :blk if (sc.len > 0) (alloc.dupe(u8, sc) catch null) else null;
        };
        defer if (superclass_dup) |s| alloc.free(s);

        // Method defined directly under this class?
        const has_method = db.prepare(
            \\SELECT 1 FROM symbols
            \\WHERE kind = 'def' AND parent_name = ? AND name = ?
            \\LIMIT 1
        ) catch return .unknown;
        defer has_method.finalize();
        has_method.bind_text(1, name);
        has_method.bind_text(2, method_name);
        if (has_method.step() catch false) return .found;

        // Follow the real superclass. If it is not itself indexed as a class/module,
        // the base lives outside the workspace (e.g. a gem/framework class) and we
        // cannot prove the method is absent — bail to .unknown rather than flag.
        if (superclass_dup) |sc| {
            const sc_known = sck: {
                const q = db.prepare(
                    \\SELECT 1 FROM symbols
                    \\WHERE name = ? AND kind IN ('class','classdef','module','moduledef') LIMIT 1
                ) catch break :sck false;
                defer q.finalize();
                q.bind_text(1, sc);
                break :sck (q.step() catch false);
            };
            if (!sc_known) return .unknown;
            const dup = alloc.dupe(u8, sc) catch return .unknown;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return .unknown;
            };
        }

        // Enqueue parent_name (carries the superclass for top-level classes; for
        // nested classes it is the namespace, deduped via `seen`).
        if (parent_name_slice.len > 0) {
            const dup = alloc.dupe(u8, parent_name_slice) catch return .unknown;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return .unknown;
            };
        }

        // Enqueue mixins (include/prepend/extend) attached to this class.
        const mix_stmt = db.prepare(
            \\SELECT module_name FROM mixins WHERE class_id = ?
        ) catch return .unknown;
        defer mix_stmt.finalize();
        mix_stmt.bind_int(1, class_id);
        while (mix_stmt.step() catch false) {
            const mod_name = mix_stmt.column_text(0);
            if (mod_name.len == 0) continue;
            const dup = alloc.dupe(u8, mod_name) catch return .unknown;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return .unknown;
            };
        }
    }

    return .not_found;
}

// Sibling of resolveMethodInAncestors that returns the resolving def's symbols.id
// instead of a verdict. Returns null when the method is not found on a fully-known
// chain, or when any ancestor is external/ambiguous — i.e. only a definite, in-index
// hit yields an id. Used to populate refs.def_id so references/rename can query a
// single binding. Kept separate from resolveMethodInAncestors so the diagnostics
// path's (hard-won, 0-FP) verdict logic is not perturbed.
fn resolveMethodSymbolInAncestors(
    db: db_mod.Db,
    class_name: []const u8,
    method_name: []const u8,
    alloc: std.mem.Allocator,
) ?i64 {
    var seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit();
    }
    var queue = std.ArrayList([]u8).empty;
    defer {
        for (queue.items) |item| alloc.free(item);
        queue.deinit(alloc);
    }

    const first = alloc.dupe(u8, class_name) catch return null;
    queue.append(alloc, first) catch {
        alloc.free(first);
        return null;
    };

    var steps: u32 = 0;
    const max_steps: u32 = 32;

    while (queue.items.len > 0) {
        if (steps >= max_steps) return null;
        steps += 1;

        const name = queue.orderedRemove(0);
        defer alloc.free(name);

        if (isBuiltinCoreClass(name)) return null; // interpreter-provided methods unseen
        if (seen.contains(name)) continue;
        const key_copy = alloc.dupe(u8, name) catch return null;
        seen.put(key_copy, {}) catch {
            alloc.free(key_copy);
            return null;
        };

        const lookup = db.prepare(
            \\SELECT id, parent_name, superclass FROM symbols
            \\WHERE name = ? AND kind IN ('class','classdef','module','moduledef')
            \\LIMIT 1
        ) catch return null;
        defer lookup.finalize();
        lookup.bind_text(1, name);
        if (!(lookup.step() catch false)) return null; // external chain — cannot link
        const class_id = lookup.column_int(0);
        const parent_name_slice = lookup.column_text(1);
        const superclass_dup: ?[]u8 = blk: {
            const sc = lookup.column_text(2);
            break :blk if (sc.len > 0) (alloc.dupe(u8, sc) catch null) else null;
        };
        defer if (superclass_dup) |s| alloc.free(s);

        // Method defined directly under this class? Return its symbol id.
        const has_method = db.prepare(
            \\SELECT id FROM symbols
            \\WHERE kind = 'def' AND parent_name = ? AND name = ?
            \\LIMIT 1
        ) catch return null;
        defer has_method.finalize();
        has_method.bind_text(1, name);
        has_method.bind_text(2, method_name);
        if (has_method.step() catch false) return has_method.column_int(0);

        if (superclass_dup) |sc| {
            const sc_known = sck: {
                const q = db.prepare(
                    \\SELECT 1 FROM symbols
                    \\WHERE name = ? AND kind IN ('class','classdef','module','moduledef') LIMIT 1
                ) catch break :sck false;
                defer q.finalize();
                q.bind_text(1, sc);
                break :sck (q.step() catch false);
            };
            if (!sc_known) return null;
            const dup = alloc.dupe(u8, sc) catch return null;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return null;
            };
        }

        if (parent_name_slice.len > 0) {
            const dup = alloc.dupe(u8, parent_name_slice) catch return null;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return null;
            };
        }

        const mix_stmt = db.prepare(
            \\SELECT module_name FROM mixins WHERE class_id = ?
        ) catch return null;
        defer mix_stmt.finalize();
        mix_stmt.bind_int(1, class_id);
        while (mix_stmt.step() catch false) {
            const mod_name = mix_stmt.column_text(0);
            if (mod_name.len == 0) continue;
            const dup = alloc.dupe(u8, mod_name) catch return null;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return null;
            };
        }
    }

    return null;
}

// True for a plain (optionally namespaced) constant name like `Foo` or `Foo::Bar`.
// Rejects union/generic receiver-type strings ("A | B", "Array[T]", "nil").
fn isBareConstantName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(s[0] >= 'A' and s[0] <= 'Z')) return false;
    for (s) |ch| {
        const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '_' or ch == ':';
        if (!ok) return false;
    }
    return true;
}

// Resolve a constant/class/module reference to the single workspace symbol that
// declares it. Returns 0 (no link) when absent or ambiguous (>1 definition) — the
// caller then leaves def_id NULL so references stays name-global for that constant.
fn resolveConstantSymbol(db: db_mod.Db, name: []const u8) i64 {
    const q = db.prepare(
        \\SELECT s.id FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE s.name = ? AND f.is_gem = 0
        \\  AND s.kind IN ('class','classdef','module','moduledef','constant')
        \\LIMIT 2
    ) catch return 0;
    defer q.finalize();
    q.bind_text(1, name);
    if (!(q.step() catch false)) return 0;
    const id0 = q.column_int(0);
    if (q.step() catch false) return 0; // ambiguous — leave NULL
    return id0;
}

// Build "ns::name" (caller frees), or just "name" when ns is empty (top-level).
fn fqnJoin(alloc: std.mem.Allocator, ns: []const u8, name: []const u8) ?[]u8 {
    if (ns.len == 0) return alloc.dupe(u8, name) catch null;
    return std.fmt.allocPrint(alloc, "{s}::{s}", .{ ns, name }) catch null;
}

// Drop the last "::segment" from a namespace ("A::B" -> "A", "A" -> ""). Slice into ns.
fn parentNs(ns: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, ns, "::")) |i| return ns[0..i];
    return "";
}

// Find the workspace symbol declaring constant/class/module `simple` directly under
// namespace `ns` ("" = top-level). Matches a nested class/module by its qualified
// name ("ns::simple"), or a constant by (name=simple, parent_name=ns). 0 when absent.
// Workspace-only (is_gem=0), mirroring resolveConstantSymbol.
fn lookupConstHere(db: db_mod.Db, ns: []const u8, simple: []const u8, alloc: std.mem.Allocator) i64 {
    if (ns.len == 0) {
        // Top-level: a class/module by bare name, or a constant with no namespace.
        // (parent_name on a top-level class can carry its superclass — the kind clause
        // keeps that from masking a real top-level class match.)
        const q = db.prepare(
            \\SELECT s.id FROM symbols s JOIN files f ON s.file_id = f.id
            \\WHERE f.is_gem = 0
            \\  AND s.kind IN ('class','classdef','module','moduledef','constant')
            \\  AND s.name = ?
            \\  AND (s.parent_name IS NULL OR s.kind IN ('class','classdef','module','moduledef'))
            \\LIMIT 1
        ) catch return 0;
        defer q.finalize();
        q.bind_text(1, simple);
        if (q.step() catch false) return q.column_int(0);
        return 0;
    }
    const fqn = fqnJoin(alloc, ns, simple) orelse return 0;
    defer alloc.free(fqn);
    const q = db.prepare(
        \\SELECT s.id FROM symbols s JOIN files f ON s.file_id = f.id
        \\WHERE f.is_gem = 0
        \\  AND s.kind IN ('class','classdef','module','moduledef','constant')
        \\  AND ( s.name = ?1 OR (s.name = ?2 AND s.parent_name = ?3) )
        \\LIMIT 1
    ) catch return 0;
    defer q.finalize();
    q.bind_text(1, fqn);
    q.bind_text(2, simple);
    q.bind_text(3, ns);
    if (q.step() catch false) return q.column_int(0);
    return 0;
}

// Descend a qualified remainder ("C::D") under an already-resolved base namespace,
// segment by segment. Returns the final symbol id, or 0 if any segment is absent.
fn descendConstPath(db: db_mod.Db, base_fqn: []const u8, rest: []const u8, alloc: std.mem.Allocator) i64 {
    if (rest.len == 0) return 0;
    var cur = alloc.dupe(u8, base_fqn) catch return 0;
    defer alloc.free(cur);
    var iter = rest;
    while (true) {
        const seg_end = std.mem.indexOf(u8, iter, "::");
        const seg = if (seg_end) |e| iter[0..e] else iter;
        const id = lookupConstHere(db, cur, seg, alloc);
        if (id == 0) return 0;
        if (seg_end == null) return id;
        const next = fqnJoin(alloc, cur, seg) orelse return 0;
        alloc.free(cur);
        cur = next;
        iter = iter[seg_end.? + 2 ..];
    }
}

// Look for constant `const_name` on the ancestry of `enclosing` (its superclass chain,
// enclosing namespace, and included/prepended/extended modules). Mirrors the method
// ancestor walk; returns the resolving symbol id or null. Only definite in-index hits.
fn resolveConstantInAncestors(db: db_mod.Db, enclosing: []const u8, const_name: []const u8, alloc: std.mem.Allocator) ?i64 {
    var seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit();
    }
    var queue = std.ArrayList([]u8).empty;
    defer {
        for (queue.items) |item| alloc.free(item);
        queue.deinit(alloc);
    }
    const first = alloc.dupe(u8, enclosing) catch return null;
    queue.append(alloc, first) catch {
        alloc.free(first);
        return null;
    };

    var steps: u32 = 0;
    const max_steps: u32 = 32;
    while (queue.items.len > 0) {
        if (steps >= max_steps) return null;
        steps += 1;

        const name = queue.orderedRemove(0);
        defer alloc.free(name);
        if (seen.contains(name)) continue;
        const key_copy = alloc.dupe(u8, name) catch return null;
        seen.put(key_copy, {}) catch {
            alloc.free(key_copy);
            return null;
        };

        // Constant/nested const defined directly under this class/module?
        const cid = lookupConstHere(db, name, const_name, alloc);
        if (cid != 0) return cid;

        // Walk superclass + enclosing namespace + mixins of this class/module.
        const lookup = db.prepare(
            \\SELECT id, parent_name, superclass FROM symbols
            \\WHERE name = ? AND kind IN ('class','classdef','module','moduledef')
            \\LIMIT 1
        ) catch return null;
        defer lookup.finalize();
        lookup.bind_text(1, name);
        if (!(lookup.step() catch false)) continue; // external/unknown — skip
        const class_id = lookup.column_int(0);
        const parent_name_slice = lookup.column_text(1);
        const sc = lookup.column_text(2);
        if (sc.len > 0) {
            const dup = alloc.dupe(u8, sc) catch return null;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return null;
            };
        }
        if (parent_name_slice.len > 0) {
            const dup = alloc.dupe(u8, parent_name_slice) catch return null;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return null;
            };
        }
        const mix_stmt = db.prepare(
            \\SELECT module_name FROM mixins WHERE class_id = ?
        ) catch return null;
        defer mix_stmt.finalize();
        mix_stmt.bind_int(1, class_id);
        while (mix_stmt.step() catch false) {
            const mod_name = mix_stmt.column_text(0);
            if (mod_name.len == 0) continue;
            const dup = alloc.dupe(u8, mod_name) catch return null;
            queue.append(alloc, dup) catch {
                alloc.free(dup);
                return null;
            };
        }
    }
    return null;
}

// Resolve a constant reference using Ruby's real lookup order: the lexical nesting at
// the ref site (innermost enclosing scope outward to top-level), then the ancestry of
// the innermost scope, then a unique-name global fallback. `ref_ns` is the enclosing
// nesting captured at index time (e.g. "A::B"; "" at top level). Returns 0 (leave
// def_id NULL → name-global fallback) when unresolved or still ambiguous.
pub fn resolveConstantNested(db: db_mod.Db, ref_name: []const u8, ref_ns: []const u8, alloc: std.mem.Allocator) i64 {
    var name = ref_name;
    var absolute = false;
    if (std.mem.startsWith(u8, name, "::")) {
        name = name[2..];
        absolute = true;
    }
    if (name.len == 0) return 0;
    const start_ns: []const u8 = if (absolute) "" else ref_ns;

    if (std.mem.indexOf(u8, name, "::")) |head_end| {
        // Qualified `Head::rest`: resolve Head lexically, then descend the remainder.
        const head = name[0..head_end];
        const rest = name[head_end + 2 ..];
        var ns = start_ns;
        while (true) {
            const head_id = lookupConstHere(db, ns, head, alloc);
            if (head_id != 0) {
                const head_fqn = fqnJoin(alloc, ns, head) orelse return 0;
                defer alloc.free(head_fqn);
                const descended = descendConstPath(db, head_fqn, rest, alloc);
                if (descended != 0) return descended;
                break; // Head matched but remainder didn't — don't jump elsewhere.
            }
            if (ns.len == 0 or absolute) break;
            ns = parentNs(ns);
        }
        // The path may itself be a stored qualified symbol name.
        const direct = lookupConstHere(db, "", name, alloc);
        if (direct != 0) return direct;
        return resolveConstantSymbol(db, ref_name);
    }

    // Bare `Const`: lexical outward walk, then ancestry, then unique global.
    var ns = start_ns;
    while (true) {
        const id = lookupConstHere(db, ns, name, alloc);
        if (id != 0) return id;
        if (ns.len == 0 or absolute) break;
        ns = parentNs(ns);
    }
    if (!absolute and ref_ns.len > 0) {
        if (resolveConstantInAncestors(db, ref_ns, name, alloc)) |id| return id;
    }
    return resolveConstantSymbol(db, ref_name);
}

// Populate refs.def_id for one file's method/constant references by resolving each
// against the (now fully-indexed) symbol table. Reads symbols globally, so for a bulk
// index it must run AFTER all files are committed. `memo` (key "class\x00method") is
// caller-owned and shared across files to avoid re-walking common ancestries; pass a
// fresh map for a single-file (incremental) call. Refs that cannot be resolved to one
// definition keep def_id NULL → handlers fall back to name-global matching.
pub fn resolveRefsForFile(db: db_mod.Db, file_id: i64, alloc: std.mem.Allocator, memo: *std.StringHashMap(i64)) void {
    // recv: receiver type for an explicit-receiver call (so `a.foo` resolves against
    // a's type, not the enclosing class). null for self-sends/untyped receivers.
    const Row = struct { rowid: i64, name: []u8, line: i64, is_const: bool, recv: ?[]u8, ns: ?[]u8 };
    var rows = std.ArrayList(Row).empty;
    defer {
        for (rows.items) |r| {
            alloc.free(r.name);
            if (r.recv) |rv| alloc.free(rv);
            if (r.ns) |n| alloc.free(n);
        }
        rows.deinit(alloc);
    }
    {
        const sel = db.prepare(
            \\SELECT rowid, name, line, kind, receiver_type, ref_ns FROM refs WHERE file_id = ? AND def_id IS NULL
        ) catch return;
        defer sel.finalize();
        sel.bind_int(1, file_id);
        while (sel.step() catch false) {
            const nm = sel.column_text(1);
            if (nm.len == 0) continue;
            const kind = sel.column_text(3);
            const is_call = std.mem.eql(u8, kind, "call") or std.mem.eql(u8, kind, "self_call");
            const is_const = (nm[0] >= 'A' and nm[0] <= 'Z') or
                (nm.len > 2 and nm[0] == ':' and nm[1] == ':' and nm[2] >= 'A' and nm[2] <= 'Z');
            if (!is_call and !is_const) continue;
            const dup = alloc.dupe(u8, nm) catch continue;
            // Only use a bare-constant receiver type; unions/generics ("A | B", "Array[T]")
            // are not resolvable to one class → leave it for enclosing-class resolution.
            var recv_dup: ?[]u8 = null;
            const rt = sel.column_text(4);
            if (rt.len > 0 and isBareConstantName(rt)) recv_dup = alloc.dupe(u8, rt) catch null;
            var ns_dup: ?[]u8 = null;
            if (is_const) {
                const rns = sel.column_text(5);
                if (rns.len > 0) ns_dup = alloc.dupe(u8, rns) catch null;
            }
            rows.append(alloc, .{ .rowid = sel.column_int(0), .name = dup, .line = sel.column_int(2), .is_const = is_const, .recv = recv_dup, .ns = ns_dup }) catch {
                alloc.free(dup);
                if (recv_dup) |rv| alloc.free(rv);
                if (ns_dup) |n| alloc.free(n);
                continue;
            };
        }
    }

    for (rows.items) |r| {
        var def_id: i64 = 0;
        if (r.is_const) {
            def_id = resolveConstantNested(db, r.name, r.ns orelse "", alloc);
        } else {
            // Resolve against the receiver's type when known, else the enclosing class.
            var class_name: ?[]u8 = null;
            var owned_enc = false;
            if (r.recv) |rv| {
                class_name = rv;
            } else if (findEnclosingClass(db, file_id, r.line, alloc)) |enc| {
                class_name = enc.name;
                owned_enc = true;
            }
            if (class_name) |cn| {
                defer if (owned_enc) alloc.free(cn);
                const key = std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ cn, r.name }) catch continue;
                if (memo.get(key)) |cached| {
                    alloc.free(key);
                    def_id = cached;
                } else {
                    def_id = resolveMethodSymbolInAncestors(db, cn, r.name, alloc) orelse 0;
                    memo.put(key, def_id) catch alloc.free(key);
                }
            }
        }
        if (def_id != 0) {
            const upd = db.prepare("UPDATE refs SET def_id = ? WHERE rowid = ?") catch continue;
            defer upd.finalize();
            upd.bind_int(1, def_id);
            upd.bind_int(2, r.rowid);
            _ = upd.step() catch {};
        }
    }
}
