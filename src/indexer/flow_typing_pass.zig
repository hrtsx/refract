const std = @import("std");
const db_mod = @import("../db.zig");
const rails_dsl = @import("rails_dsl.zig");

// Post-index flow-typing pass. Resolves the deferred `@ivar = recv.method` typings
// captured in pending_recv_returns over the COMPLETE symbol table — looking up the
// method's return type SCOPED to the receiver's class. Replaces the old single-pass
// index-write lookup that read a partially-built table (racy) and grabbed any same-named
// def's return (imprecise). Runs once after a full cold index, under the db mutex.
//
// Determinism: every selection has a content-stable ORDER BY, so the result is identical
// regardless of the nondeterministic parallel-index row order. FP-safety: writes land at
// confidence 50 (< the 70 diagnostic gate), so diagnostics never read these types — no new
// false positives. Idempotent: only updates rows whose type_hint is still NULL.
pub fn runFlowTypingPass(db: db_mod.Db) void {
    // Const-rooted AR chain defs (`def prunable_accounts; Account.remote.where...; end`).
    // Runs FIRST so a chain-typed method's return feeds the const-receiver local pass below
    // (`x = Foo.chain_method` → `x : [Model]`). Gated on the root being AR-shaped (owns a
    // scope/association), so a plain `Config.load.freeze` on a non-model types nothing — the
    // gate is the FP guard. `[Root]` for a relation terminal, `Root` for a singular one.
    db.exec(
        \\UPDATE symbols SET return_type = (
        \\    SELECT CASE WHEN p.singular=1 THEN p.root_const ELSE '['||p.root_const||']' END
        \\    FROM pending_chain_returns p
        \\    WHERE p.file_id=symbols.file_id AND p.line=symbols.line AND p.col=symbols.col
        \\      AND EXISTS (SELECT 1 FROM symbols m WHERE m.kind IN ('scope','association')
        \\        AND (m.parent_name=p.root_const OR m.parent_name LIKE '%::'||p.root_const))
        \\    LIMIT 1
        \\  )
        \\WHERE kind IN ('def','classdef') AND return_type IS NULL AND EXISTS (
        \\    SELECT 1 FROM pending_chain_returns p
        \\    WHERE p.file_id=symbols.file_id AND p.line=symbols.line AND p.col=symbols.col
        \\      AND EXISTS (SELECT 1 FROM symbols m WHERE m.kind IN ('scope','association')
        \\        AND (m.parent_name=p.root_const OR m.parent_name LIKE '%::'||p.root_const)));
    ) catch {};

    // self / implicit-self receiver: `@x = helper` / `@x = self.helper` — resolve the
    // method's return on the enclosing class (and its `%::Name` namespaced form).
    db.exec(
        \\UPDATE local_vars SET type_hint = (
        \\    SELECT s.return_type FROM symbols s, pending_recv_returns p, symbols cls
        \\    WHERE p.file_id=local_vars.file_id AND p.ivar_name=local_vars.name AND p.line=local_vars.line AND p.col=local_vars.col
        \\      AND p.recv_kind='self' AND cls.id=p.class_id
        \\      AND s.name=p.method_name AND s.kind IN ('def','association','scope') AND s.return_type IS NOT NULL
        \\      AND (s.parent_name=cls.name OR s.parent_name LIKE '%::'||cls.name)
        \\    ORDER BY (s.parent_name=cls.name) DESC, s.return_type LIMIT 1
        \\  ), confidence=50
        \\WHERE local_vars.type_hint IS NULL AND EXISTS (
        \\    SELECT 1 FROM pending_recv_returns p, symbols cls, symbols s
        \\    WHERE p.file_id=local_vars.file_id AND p.ivar_name=local_vars.name AND p.line=local_vars.line AND p.col=local_vars.col
        \\      AND p.recv_kind='self' AND cls.id=p.class_id
        \\      AND s.name=p.method_name AND s.kind IN ('def','association','scope') AND s.return_type IS NOT NULL
        \\      AND (s.parent_name=cls.name OR s.parent_name LIKE '%::'||cls.name));
    ) catch {};

    // constant receiver: `@x = SomeService.call` — resolve the method's return on the named
    // class (class method / scope, falling back to instance defs).
    db.exec(
        \\UPDATE local_vars SET type_hint = (
        \\    SELECT s.return_type FROM symbols s, pending_recv_returns p
        \\    WHERE p.file_id=local_vars.file_id AND p.ivar_name=local_vars.name AND p.line=local_vars.line AND p.col=local_vars.col
        \\      AND p.recv_kind='const'
        \\      AND s.name=p.method_name AND s.kind IN ('classdef','scope','def') AND s.return_type IS NOT NULL
        \\      AND (s.parent_name=p.recv_name OR s.parent_name LIKE '%::'||p.recv_name)
        \\    ORDER BY (s.parent_name=p.recv_name) DESC, s.return_type LIMIT 1
        \\  ), confidence=50
        \\WHERE local_vars.type_hint IS NULL AND EXISTS (
        \\    SELECT 1 FROM pending_recv_returns p, symbols s
        \\    WHERE p.file_id=local_vars.file_id AND p.ivar_name=local_vars.name AND p.line=local_vars.line AND p.col=local_vars.col
        \\      AND p.recv_kind='const'
        \\      AND s.name=p.method_name AND s.kind IN ('classdef','scope','def') AND s.return_type IS NOT NULL
        \\      AND (s.parent_name=p.recv_name OR s.parent_name LIKE '%::'||p.recv_name));
    ) catch {};

    // instance-variable receiver: `@x = @y.method` — resolve @y's recorded type (same class
    // scope), then the method's return on that class. Precise (vs the unscoped fallback) so
    // it runs first. @y must already be typed (inline new/finder, or the self/const passes).
    db.exec(
        \\UPDATE local_vars SET type_hint = (
        \\    SELECT s.return_type FROM symbols s, pending_recv_returns p
        \\    WHERE p.file_id=local_vars.file_id AND p.ivar_name=local_vars.name AND p.line=local_vars.line AND p.col=local_vars.col
        \\      AND p.recv_kind='ivar'
        \\      AND s.name=p.method_name AND s.kind IN ('def','association','scope') AND s.return_type IS NOT NULL
        \\      AND (s.parent_name=(SELECT lv2.type_hint FROM local_vars lv2 WHERE lv2.class_id=p.class_id AND lv2.name=p.recv_name AND lv2.type_hint IS NOT NULL ORDER BY lv2.confidence DESC, lv2.type_hint LIMIT 1)
        \\        OR s.parent_name LIKE '%::'||(SELECT lv2.type_hint FROM local_vars lv2 WHERE lv2.class_id=p.class_id AND lv2.name=p.recv_name AND lv2.type_hint IS NOT NULL ORDER BY lv2.confidence DESC, lv2.type_hint LIMIT 1))
        \\    ORDER BY s.return_type LIMIT 1
        \\  ), confidence=50
        \\WHERE local_vars.type_hint IS NULL AND EXISTS (
        \\    SELECT 1 FROM pending_recv_returns p, symbols s
        \\    WHERE p.file_id=local_vars.file_id AND p.ivar_name=local_vars.name AND p.line=local_vars.line AND p.col=local_vars.col
        \\      AND p.recv_kind='ivar'
        \\      AND s.name=p.method_name AND s.kind IN ('def','association','scope') AND s.return_type IS NOT NULL
        \\      AND (s.parent_name=(SELECT lv2.type_hint FROM local_vars lv2 WHERE lv2.class_id=p.class_id AND lv2.name=p.recv_name AND lv2.type_hint IS NOT NULL ORDER BY lv2.confidence DESC, lv2.type_hint LIMIT 1)
        \\        OR s.parent_name LIKE '%::'||(SELECT lv2.type_hint FROM local_vars lv2 WHERE lv2.class_id=p.class_id AND lv2.name=p.recv_name AND lv2.type_hint IS NOT NULL ORDER BY lv2.confidence DESC, lv2.type_hint LIMIT 1)));
    ) catch {};

    // Unscoped fallback (recv type unresolved — an ivar/local/chain receiver). Pick the
    // method's return type from ANY class deterministically (content ORDER BY) — the old
    // single-pass behavior, but now stable. Lower confidence (40) marks it imprecise. Only
    // touches rows the scoped passes above left NULL.
    db.exec(
        \\UPDATE local_vars SET type_hint = (
        \\    SELECT s.return_type FROM symbols s, pending_recv_returns p
        \\    WHERE p.file_id=local_vars.file_id AND p.ivar_name=local_vars.name AND p.line=local_vars.line AND p.col=local_vars.col
        \\      AND s.name=p.method_name AND s.kind IN ('def','classdef','scope') AND s.return_type IS NOT NULL
        \\    ORDER BY s.return_type LIMIT 1
        \\  ), confidence=40
        \\WHERE local_vars.type_hint IS NULL AND EXISTS (
        \\    SELECT 1 FROM pending_recv_returns p, symbols s
        \\    WHERE p.file_id=local_vars.file_id AND p.ivar_name=local_vars.name AND p.line=local_vars.line AND p.col=local_vars.col
        \\      AND s.name=p.method_name AND s.kind IN ('def','classdef','scope') AND s.return_type IS NOT NULL);
    ) catch {};

    // Block-yield element typing: `xs.each { |x| }` / `@xs.map { |x| }` where the receiver's type
    // was unknown at index time (typed only by the local/ivar passes above). Resolves the
    // receiver's now-complete type and applies element extraction. Runs LAST so it sees every
    // type the passes above wrote. Confidence 50 (< 70 gate) and NULL-gated — completion-only,
    // never an FP, never overrides a higher-confidence index-time typing.
    resolveBlockYields(db);
}

fn dupSlice(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len == 0 or s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

fn resolveBlockYields(db: db_mod.Db) void {
    const sel = db.prepare("SELECT file_id, param_name, line, col, recv_name, method_name FROM pending_block_yields") catch return;
    defer sel.finalize();
    const recv_stmt = db.prepare("SELECT type_hint FROM local_vars WHERE file_id=? AND name=? AND type_hint IS NOT NULL ORDER BY confidence DESC, line DESC LIMIT 1") catch return;
    defer recv_stmt.finalize();
    const upd = db.prepare("UPDATE local_vars SET type_hint=?, confidence=50 WHERE file_id=? AND name=? AND line=? AND col=? AND type_hint IS NULL") catch return;
    defer upd.finalize();
    while (sel.step() catch false) {
        const file_id = sel.column_int(0);
        var pbuf: [128]u8 = undefined;
        var rbuf: [128]u8 = undefined;
        var mbuf: [64]u8 = undefined;
        const pname = dupSlice(&pbuf, sel.column_text(1)) orelse continue;
        const line = sel.column_int(2);
        const col = sel.column_int(3);
        const rname = dupSlice(&rbuf, sel.column_text(4)) orelse continue;
        const method = dupSlice(&mbuf, sel.column_text(5)) orelse continue;
        recv_stmt.reset();
        recv_stmt.bind_int(1, file_id);
        recv_stmt.bind_text(2, rname);
        var tbuf: [128]u8 = undefined;
        const recv_type: ?[]const u8 = blk: {
            if (recv_stmt.step() catch false) {
                const t = recv_stmt.column_text(0);
                if (t.len > 0 and t.len <= tbuf.len) {
                    @memcpy(tbuf[0..t.len], t);
                    break :blk tbuf[0..t.len];
                }
            }
            break :blk null;
        };
        const rt = recv_type orelse continue;
        const elem = rails_dsl.blockElemType(method, rt) orelse continue;
        upd.reset();
        upd.bind_text(1, elem);
        upd.bind_int(2, file_id);
        upd.bind_text(3, pname);
        upd.bind_int(4, line);
        upd.bind_int(5, col);
        _ = upd.step() catch {};
    }
}
