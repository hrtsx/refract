const std = @import("std");
const build_meta = @import("build_meta");
const db_mod = @import("db.zig");
const transport = @import("lsp/transport.zig");
const types = @import("lsp/types.zig");
const server_mod = @import("lsp/server.zig");
const mcp = @import("mcp/server.zig");
const dap_server = @import("dap/server.zig");
const indexer = @import("indexer/index.zig");
const scanner = @import("indexer/scanner.zig");
const gems = @import("indexer/gems.zig");
const crash = @import("lsp/crash.zig");
const doctor = @import("cli/doctor.zig");
const sandbox = @import("lsp/sandbox.zig");
const sorbet_harness = @import("tests/sorbet_harness.zig");

comptime {
    _ = @import("tests/type_resolver_test.zig");
}

pub const Panic = crash.Panic;

var stdin_buf: [65536]u8 = undefined;
var stdout_buf: [65536]u8 = undefined;

const REINDEX_BUFFER_BYTES: usize = 8 * 1024 * 1024;

var g_sigterm = std.atomic.Value(bool).init(false);
var g_tmp_dir: ?[:0]u8 = null;

fn onSigterm(_: std.posix.SIG) callconv(.c) void {
    g_sigterm.store(true, .seq_cst);
    _ = std.c.alarm(3); // hard-exit ceiling: cleanup must complete within 3s
}

fn onSigalrm(_: std.posix.SIG) callconv(.c) void {
    std.c.exit(130);
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const io = init.io;

    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const args = try init.minimal.args.toSlice(args_arena.allocator());

    // Sandbox trampoline: refract spawns itself with --sandbox-exec to apply
    // seccomp/Landlock/rlimits to a plugin before execve'ing it. Filter
    // persists across exec so the plugin runs sandboxed without cooperation.
    //
    // Syntax: refract --sandbox-exec [--allow-network] [--allow-fs-write=PATH]... -- ENTRY
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--sandbox-exec")) {
        try runSandboxExec(alloc, io, args);
        return; // execve replaces this process; if it returns, we exit error
    }

    var server_log_path: ?[]const u8 = null;
    var server_log_level: u8 = 2;
    var server_disable_rubocop: bool = false;
    var server_disable_hot_index: bool = false;
    var server_disable_warmup: bool = false;
    var custom_db_path: ?[]const u8 = null;
    var flag_reset_db: bool = false;
    var flag_print_db_path: bool = false;
    var flag_check: bool = false;
    var flag_stats: bool = false;
    var flag_mcp: bool = false;
    var flag_dap: bool = false;
    var flag_index_only: bool = false;
    var flag_warm_stdlib: bool = false;
    var flag_dump_symbols: bool = false;
    var flag_workspace_info: bool = false;
    var flag_max_workers: ?u32 = null;
    var flag_json: bool = false;
    var flag_last_crash: bool = false;
    var flag_doctor: bool = false;
    var flag_repair: bool = false;
    var bench_sorbet_root: ?[]const u8 = null;
    var bench_steep_root: ?[]const u8 = null;
    var flag_no_color: bool = false;
    var flag_self_test: bool = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try std.Io.File.stdout().writeStreamingAll(io, "refract " ++ build_meta.version ++ "\n");
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.Io.File.stdout().writeStreamingAll(
                io,
                "Usage: refract\n" ++
                    "  Ruby LSP server (communicates over stdin/stdout)\n\n" ++
                    "Flags:\n" ++
                    "  --version            Print version and exit\n" ++
                    "  --help               Print this message and exit\n" ++
                    "  --log-file FILE      Write logs to FILE\n" ++
                    "  --verbose            Enable verbose logging\n" ++
                    "  --log-level 1|2|3|4  Set log verbosity (1=error … 4=debug)\n" ++
                    "  --disable-rubocop    Disable RuboCop diagnostics\n" ++
                    "  --no-color           Disable colored output (or set NO_COLOR env var)\n" ++
                    "  --no-hot-index       Disable in-memory hot symbol index (A/B for benchmarks)\n" ++
                    "  --no-warmup          Disable hot index warmup on initialize (A/B for benchmarks)\n" ++
                    "  --db-path PATH       Override database file path\n" ++
                    "  --print-db-path      Print computed database path and exit\n" ++
                    "  --reset-db           Delete the database and exit\n" ++
                    "  --check              Verify database integrity and exit 0/1\n" ++
                    "  --stats              Print index statistics and exit\n" ++
                    "  --json               Output statistics as JSON (with --stats)\n" ++
                    "  --max-workers N      Set max indexing worker threads\n" ++
                    "  --index-only         Index workspace and exit\n" ++
                    "  --dump-symbols       Dump all indexed symbols as JSON and exit\n" ++
                    "  --workspace-info     Print workspace info and exit\n" ++
                    "  --last-crash         Print most recent crash log and exit\n" ++
                    "  --doctor             Print diagnostic report (colored checklist)\n" ++
                    "  --repair             Perform safe repairs (with --doctor)\n" ++
                    "  --dap                Run as Debug Adapter Protocol server\n" ++
                    "  --warm-stdlib        Index standard library and exit\n" ++
                    "  --bench-sorbet PATH  Benchmark against Sorbet on a project\n" ++
                    "  --bench-steep PATH   Benchmark against Steep on a project\n" ++
                    "  --mcp                Run as MCP server\n" ++
                    "  --self-test          Spawn LSP+MCP child handshakes and exit 0 on success\n",
            );
            return;
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            if (i + 1 >= args.len) {
                try std.Io.File.stderr().writeStreamingAll(io, "refract: --log-file requires a value\n");
                return error.InvalidArgument;
            }
            i += 1;
            server_log_path = args[i];
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            server_log_level = 3;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            if (i + 1 >= args.len) {
                try std.Io.File.stderr().writeStreamingAll(io, "refract: --log-level requires a value\n");
                return error.InvalidArgument;
            }
            i += 1;
            const lvl = std.fmt.parseInt(u8, args[i], 10) catch 2;
            server_log_level = @max(1, @min(lvl, 4));
        } else if (std.mem.eql(u8, arg, "--disable-rubocop")) {
            server_disable_rubocop = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            flag_no_color = true;
        } else if (std.mem.eql(u8, arg, "--no-hot-index")) {
            server_disable_hot_index = true;
        } else if (std.mem.eql(u8, arg, "--no-warmup")) {
            server_disable_warmup = true;
        } else if (std.mem.eql(u8, arg, "--db-path")) {
            if (i + 1 >= args.len) {
                try std.Io.File.stderr().writeStreamingAll(io, "refract: --db-path requires a value\n");
                return error.InvalidArgument;
            }
            i += 1;
            custom_db_path = args[i];
        } else if (std.mem.eql(u8, arg, "--reset-db")) {
            flag_reset_db = true;
        } else if (std.mem.eql(u8, arg, "--print-db-path")) {
            flag_print_db_path = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            flag_check = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            flag_stats = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            flag_json = true;
        } else if (std.mem.eql(u8, arg, "--max-workers")) {
            i += 1;
            if (i < args.len) {
                flag_max_workers = std.fmt.parseInt(u32, args[i], 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--mcp")) {
            flag_mcp = true;
        } else if (std.mem.eql(u8, arg, "--dap")) {
            flag_dap = true;
        } else if (std.mem.eql(u8, arg, "--index-only")) {
            flag_index_only = true;
        } else if (std.mem.eql(u8, arg, "--warm-stdlib")) {
            flag_warm_stdlib = true;
        } else if (std.mem.eql(u8, arg, "--dump-symbols")) {
            flag_dump_symbols = true;
        } else if (std.mem.eql(u8, arg, "--workspace-info")) {
            flag_workspace_info = true;
        } else if (std.mem.eql(u8, arg, "--last-crash")) {
            flag_last_crash = true;
        } else if (std.mem.eql(u8, arg, "--doctor")) {
            flag_doctor = true;
        } else if (std.mem.eql(u8, arg, "--repair")) {
            flag_repair = true;
        } else if (std.mem.eql(u8, arg, "--self-test")) {
            flag_self_test = true;
        } else if (std.mem.eql(u8, arg, "--bench-sorbet")) {
            if (i + 1 >= args.len) {
                try std.Io.File.stderr().writeStreamingAll(io, "refract: --bench-sorbet requires a project root path\n");
                return error.InvalidArgument;
            }
            i += 1;
            bench_sorbet_root = args[i];
        } else if (std.mem.eql(u8, arg, "--bench-steep")) {
            if (i + 1 >= args.len) {
                try std.Io.File.stderr().writeStreamingAll(io, "refract: --bench-steep requires a project root path\n");
                return error.InvalidArgument;
            }
            i += 1;
            bench_steep_root = args[i];
        } else if (std.mem.startsWith(u8, arg, "--") and !std.mem.eql(u8, arg, "--stdio")) {
            var wbuf: [256]u8 = undefined;
            const wmsg = std.fmt.bufPrint(&wbuf, "refract: unrecognized flag: {s}\n", .{arg}) catch "refract: unrecognized flag\n";
            try std.Io.File.stderr().writeStreamingAll(io, wmsg);
            return error.InvalidArgument;
        }
    }

    if (comptime @import("builtin").os.tag != .windows) {
        std.posix.sigaction(std.posix.SIG.PIPE, &.{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        const term_act = std.posix.Sigaction{
            .handler = .{ .handler = onSigterm },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &term_act, null);
        std.posix.sigaction(std.posix.SIG.INT, &term_act, null);
        const alrm_act = std.posix.Sigaction{
            .handler = .{ .handler = onSigalrm },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.ALRM, &alrm_act, null);
    }

    if (flag_dap) {
        const dap_cwd = try std.process.currentPathAlloc(io, alloc);
        defer alloc.free(dap_cwd);
        var dsrv = dap_server.Server.init(alloc, io);
        dsrv.cwd = dap_cwd;
        try dsrv.run();
        return;
    }

    const cwd = try std.process.currentPathAlloc(io, alloc);
    defer alloc.free(cwd);
    const computed_db_path: ?[]u8 = if (custom_db_path == null) try server_mod.computeDbPath(alloc, cwd) else null;
    defer if (computed_db_path) |p| alloc.free(p);
    const db_path: []const u8 = if (custom_db_path) |p| p else computed_db_path.?;

    if (custom_db_path) |p| {
        if (!std.fs.path.isAbsolute(p)) {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --db-path must be an absolute path\n");
            return error.InvalidArgument;
        }
    }

    if (flag_print_db_path) {
        try std.Io.File.stdout().writeStreamingAll(io, db_path);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        return;
    }

    if (flag_reset_db) {
        var buf: [4096]u8 = undefined;
        std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, db_path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => {
                const msg = std.fmt.bufPrint(&buf, "refract: --reset-db: could not delete {s}: {s}\n", .{ db_path, @errorName(e) }) catch "refract: --reset-db failed\n";
                try std.Io.File.stderr().writeStreamingAll(io, msg);
                return error.ResetDbFailed;
            },
        };
        for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
            const side = std.fmt.bufPrint(&buf, "{s}{s}", .{ db_path, suffix }) catch continue;
            std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, side) catch {};
        }
        const msg = std.fmt.bufPrint(&buf, "refract: database reset: {s}\n", .{db_path}) catch "refract: database reset\n";
        try std.Io.File.stdout().writeStreamingAll(io, msg);
        return;
    }

    if (flag_last_crash) {
        var stdout_w_buf: [4096]u8 = undefined;
        var fw = std.Io.File.stdout().writerStreaming(io, &stdout_w_buf);
        const w = &fw.interface;
        crash.dumpLastCrash(io, alloc, w) catch |e| switch (e) {
            error.NoCrashLog, error.NoStateDir => {
                try std.Io.File.stdout().writeStreamingAll(io, "refract: no crash log found\n");
                return;
            },
            else => return e,
        };
        try w.flush();
        return;
    }

    if (flag_doctor) {
        const no_color = flag_no_color or (std.c.getenv("NO_COLOR") != null);
        const opts = doctor.DoctorOptions{
            .json = flag_json,
            .repair = flag_repair,
            .no_color = no_color,
        };
        const had_fail = try doctor.runDoctor(io, db_path, cwd, opts, alloc);
        // Explicit non-zero exit on hard fails so `refract --doctor` can be
        // used as a CI / install-verify gate. (`return error.DoctorFailed`
        // produced a stack-trace dump on stderr — confusing for shell users.)
        std.process.exit(if (had_fail) 1 else 0);
    }

    if (flag_self_test) {
        try runSelfTest(io, alloc);
        return;
    }

    if (bench_sorbet_root != null or bench_steep_root != null) {
        try runBenchSorbetSteep(io, alloc, bench_sorbet_root, bench_steep_root);
        return;
    }

    if (flag_check or flag_stats) {
        const check_pathz = try alloc.dupeZ(u8, db_path);
        defer alloc.free(check_pathz);
        const check_db = db_mod.Db.open(check_pathz) catch {
            try std.Io.File.stdout().writeStreamingAll(io, "FAIL: could not open database\n");
            return error.DatabaseOpen;
        };
        defer check_db.close();

        if (flag_check) {
            check_db.init_schema() catch {
                try std.Io.File.stdout().writeStreamingAll(io, "FAIL: schema init failed\n");
                return error.DatabaseOpen;
            };
            check_db.check_integrity() catch {
                try std.Io.File.stdout().writeStreamingAll(io, "FAIL: database corrupted\n");
                return error.CorruptDatabase;
            };
            const count_stmt = check_db.prepare("SELECT COUNT(*) FROM files") catch {
                try std.Io.File.stdout().writeStreamingAll(io, "FAIL: could not query files\n");
                return error.DatabaseOpen;
            };
            defer count_stmt.finalize();
            const n: i64 = if (try count_stmt.step()) count_stmt.column_int(0) else 0;
            var out_buf: [512]u8 = undefined;
            const out = std.fmt.bufPrint(&out_buf, "OK\n  files: {d}\n  db: {s}\n", .{ n, db_path }) catch "OK\n";
            try std.Io.File.stdout().writeStreamingAll(io, out);
            return;
        }

        if (flag_stats) {
            check_db.init_schema() catch {
                try std.Io.File.stdout().writeStreamingAll(io, "FAIL: schema init failed\n");
                return error.DatabaseOpen;
            };
            const files_stmt = check_db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=0") catch {
                try std.Io.File.stdout().writeStreamingAll(io, "FAIL: could not query stats\n");
                return error.DatabaseOpen;
            };
            defer files_stmt.finalize();
            const nfiles: i64 = if (try files_stmt.step()) files_stmt.column_int(0) else 0;

            const gems_stmt = check_db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=1") catch {
                try std.Io.File.stdout().writeStreamingAll(io, "FAIL: could not query stats\n");
                return error.DatabaseOpen;
            };
            defer gems_stmt.finalize();
            const ngems: i64 = if (try gems_stmt.step()) gems_stmt.column_int(0) else 0;

            const syms_stmt = check_db.prepare("SELECT COUNT(*) FROM symbols") catch {
                try std.Io.File.stdout().writeStreamingAll(io, "FAIL: could not query stats\n");
                return error.DatabaseOpen;
            };
            defer syms_stmt.finalize();
            const nsyms: i64 = if (try syms_stmt.step()) syms_stmt.column_int(0) else 0;

            const schema_stmt = check_db.prepare("SELECT value FROM meta WHERE key='schema_version'") catch {
                try std.Io.File.stdout().writeStreamingAll(io, "FAIL: could not query stats\n");
                return error.DatabaseOpen;
            };
            defer schema_stmt.finalize();
            const schema_ver: []const u8 = if (try schema_stmt.step()) schema_stmt.column_text(0) else "unknown";

            if (flag_json) {
                var aw = std.Io.Writer.Allocating.init(alloc);
                try aw.writer.writeAll("{\"db\":\"");
                try aw.writer.writeAll(db_path);
                try aw.writer.print("\",\"schema\":\"{s}\",\"files\":{d},\"gems\":{d},\"symbols\":{d}}}", .{ schema_ver, nfiles, ngems, nsyms });
                const result = try aw.toOwnedSlice();
                defer alloc.free(result);
                try std.Io.File.stdout().writeStreamingAll(io, result);
                try std.Io.File.stdout().writeStreamingAll(io, "\n");
            } else {
                var out_buf: [1024]u8 = undefined;
                const out = std.fmt.bufPrint(
                    &out_buf,
                    "db:      {s}\nschema:  {s}\nfiles:   {d}\ngems:    {d}\nsymbols: {d}\n",
                    .{ db_path, schema_ver, nfiles, ngems, nsyms },
                ) catch "FAIL: format error\n";
                try std.Io.File.stdout().writeStreamingAll(io, out);
            }
            return;
        }
    }

    if (flag_warm_stdlib) {
        const warm_pathz = try alloc.dupeZ(u8, db_path);
        defer alloc.free(warm_pathz);
        const warm_db = db_mod.Db.open(warm_pathz) catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --warm-stdlib: could not open database\n");
            return error.DatabaseOpen;
        };
        defer warm_db.close();
        warm_db.init_schema() catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --warm-stdlib: schema init failed\n");
            return error.DatabaseOpen;
        };
        indexStdlibRbs(io, warm_db, cwd, alloc);
        // Only mark stdlib as indexed if it actually was — otherwise downstream
        // refract instances would skip stdlib indexing on a template that has none.
        var stdlib_count: i64 = 0;
        if (warm_db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=1 AND path NOT LIKE '<bundled>/%'")) |s| {
            defer s.finalize();
            if (s.step() catch false) stdlib_count = s.column_int(0);
        } else |_| {}
        if (stdlib_count > 0) {
            server_mod.setMetaInt(warm_db, "stdlib_rbs_indexed", 1, alloc);
        }
        return;
    }

    if (flag_index_only) {
        const index_pathz = try alloc.dupeZ(u8, db_path);
        defer alloc.free(index_pathz);
        const index_db = db_mod.Db.open(index_pathz) catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --index-only: could not open database\n");
            return error.DatabaseOpen;
        };
        defer index_db.close();

        index_db.init_schema() catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --index-only: schema init failed\n");
            return error.DatabaseOpen;
        };

        const workspace_root = cwd;
        const paths = scanner.scanWithNegations(workspace_root, alloc, &.{}, &.{}) catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --index-only: workspace scan failed\n");
            return error.ScanFailed;
        };
        defer {
            for (paths) |p| alloc.free(p);
            alloc.free(paths);
        }

        const const_paths = try alloc.alloc([]const u8, paths.len);
        defer alloc.free(const_paths);
        for (paths, 0..) |p, idx| const_paths[idx] = p;

        indexer.reindex(index_db, const_paths, false, alloc, REINDEX_BUFFER_BYTES, null) catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --index-only: reindex failed\n");
            return error.IndexFailed;
        };

        var files_stmt = index_db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=0") catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --index-only: could not query file count\n");
            return error.DatabaseOpen;
        };
        defer files_stmt.finalize();
        const nfiles: i64 = if (try files_stmt.step()) files_stmt.column_int(0) else 0;

        var syms_stmt = index_db.prepare("SELECT COUNT(*) FROM symbols") catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --index-only: could not query symbol count\n");
            return error.DatabaseOpen;
        };
        defer syms_stmt.finalize();
        const nsyms: i64 = if (try syms_stmt.step()) syms_stmt.column_int(0) else 0;

        var out_buf: [256]u8 = undefined;
        const out = std.fmt.bufPrint(&out_buf, "Indexed {d} files, {d} symbols\n", .{ nfiles, nsyms }) catch "Indexed workspace\n";
        try std.Io.File.stdout().writeStreamingAll(io, out);
        return;
    }

    if (flag_dump_symbols) {
        const dump_pathz = try alloc.dupeZ(u8, db_path);
        defer alloc.free(dump_pathz);
        const dump_db = db_mod.Db.open(dump_pathz) catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --dump-symbols: could not open database\n");
            return error.DatabaseOpen;
        };
        defer dump_db.close();

        dump_db.init_schema() catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --dump-symbols: schema init failed\n");
            return error.DatabaseOpen;
        };

        const query = "SELECT s.name, s.kind, s.line, s.col, s.return_type, f.path FROM symbols s JOIN files f ON s.file_id=f.id WHERE f.is_gem=0 ORDER BY f.path, s.line";
        var stmt = dump_db.prepare(query) catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --dump-symbols: query failed\n");
            return error.DatabaseOpen;
        };
        defer stmt.finalize();

        var aw = std.Io.Writer.Allocating.init(alloc);
        try aw.writer.writeAll("[");

        var first = true;
        while (try stmt.step()) {
            if (!first) try aw.writer.writeAll(",");
            first = false;

            const sym_name = stmt.column_text(0);
            const sym_kind = stmt.column_text(1);
            const sym_line = stmt.column_int(2);
            const sym_col = stmt.column_int(3);
            const sym_return_type = stmt.column_text(4);
            const file_path = stmt.column_text(5);

            try aw.writer.writeAll("{\"name\":");
            try writeJsonString(&aw.writer, sym_name);
            try aw.writer.writeAll(",\"kind\":");
            try writeJsonString(&aw.writer, sym_kind);
            try aw.writer.print(",\"line\":{d},\"col\":{d}", .{ sym_line, sym_col });
            try aw.writer.writeAll(",\"file\":");
            try writeJsonString(&aw.writer, file_path);
            try aw.writer.writeAll(",\"return_type\":");
            try writeJsonString(&aw.writer, sym_return_type);
            try aw.writer.writeAll("}");
        }

        try aw.writer.writeAll("]");
        const result = try aw.toOwnedSlice();
        defer alloc.free(result);
        try std.Io.File.stdout().writeStreamingAll(io, result);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        return;
    }

    if (flag_workspace_info) {
        const info_pathz = try alloc.dupeZ(u8, db_path);
        defer alloc.free(info_pathz);
        const info_db = db_mod.Db.open(info_pathz) catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --workspace-info: could not open database\n");
            return error.DatabaseOpen;
        };
        defer info_db.close();

        info_db.init_schema() catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: --workspace-info: schema init failed\n");
            return error.DatabaseOpen;
        };

        var total_files: i64 = 0;
        if (info_db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=0")) |stmt| {
            defer stmt.finalize();
            if (try stmt.step()) total_files = stmt.column_int(0);
        } else |_| {}

        var gem_files: i64 = 0;
        if (info_db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=1")) |stmt| {
            defer stmt.finalize();
            if (try stmt.step()) gem_files = stmt.column_int(0);
        } else |_| {}

        var schema_buf: [32]u8 = undefined;
        var schema_ver: []const u8 = "unknown";
        if (info_db.prepare("SELECT value FROM meta WHERE key='schema_version'")) |stmt| {
            defer stmt.finalize();
            if (try stmt.step()) {
                const src = stmt.column_text(0);
                const n = @min(src.len, schema_buf.len);
                @memcpy(schema_buf[0..n], src[0..n]);
                schema_ver = schema_buf[0..n];
            }
        } else |_| {}

        const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, db_path, .{}) catch {
            return error.DatabaseOpen;
        };
        const db_size_bytes = stat.size;

        var out_buf: [2048]u8 = undefined;
        const out = std.fmt.bufPrint(
            &out_buf,
            "Workspace Info\n" ++
                "==============\n" ++
                "Database:     {s}\n" ++
                "Size:         {d} bytes\n" ++
                "Schema:       {s}\n" ++
                "Files:        {d}\n" ++
                "Gems:         {d}\n",
            .{ db_path, db_size_bytes, schema_ver, total_files, gem_files },
        ) catch "refract: format error\n";
        try std.Io.File.stdout().writeStreamingAll(io, out);

        if (info_db.prepare("SELECT kind, COUNT(*) FROM symbols GROUP BY kind ORDER BY COUNT(*) DESC")) |stmt| {
            defer stmt.finalize();
            var output = std.ArrayList(u8).empty;
            defer output.deinit(alloc);

            try output.appendSlice(alloc, "\nSymbols by Kind\n" ++
                "===============\n");

            while (try stmt.step()) {
                const kind = stmt.column_text(0);
                const count = stmt.column_int(1);
                const line = std.fmt.allocPrint(alloc, "{s:20} {d}\n", .{ kind, count }) catch continue;
                defer alloc.free(line);
                try output.appendSlice(alloc, line);
            }

            try std.Io.File.stdout().writeStreamingAll(io, output.items);
        } else |_| {}

        return;
    }

    const db_pathz = try alloc.dupeZ(u8, db_path);
    defer alloc.free(db_pathz);

    // Single-instance locking: prevent two servers from writing to the same DB.
    // MCP mode skips locking — it only reads, and SQLite WAL handles concurrent readers.
    // Uses flock() so the kernel auto-releases the lock on any exit (clean, panic, SIGKILL).
    var lock_file: ?std.Io.File = null;
    var lock_path: ?[]u8 = null;
    if (!flag_mcp) {
        lock_path = try std.fmt.allocPrint(alloc, "{s}.lock", .{db_path});
        const lf = try std.Io.Dir.cwd().createFile(std.Options.debug_io, lock_path.?, .{ .exclusive = false });
        if (std.c.flock(lf.handle, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
            const flock_err = std.c.errno(-1);
            lf.close(io);
            if (flock_err == .AGAIN) {
                try std.Io.File.stderr().writeStreamingAll(io, "refract: another instance is already running with this database\n");
                return;
            }
            return error.Unexpected;
        }
        lock_file = lf;
        var pid_buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.c.getpid()}) catch "";
        lf.writeStreamingAll(io, pid_str) catch {};
    }
    defer {
        if (lock_file) |lf| lf.close(io);
        if (lock_path) |lp| {
            std.Io.Dir.cwd().deleteFile(std.Options.debug_io, lp) catch {};
            alloc.free(lp);
        }
    }

    const profiling = std.c.getenv("REFRACT_INIT_PROFILE") != null;
    const main_start = if (profiling) std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() else 0;
    const db = db_mod.Db.open(db_pathz) catch {
        try std.Io.File.stderr().writeStreamingAll(io, "refract: failed to open database\n");
        return error.DatabaseOpen;
    };
    defer {
        db.checkpoint();
        db.close();
    }
    try db.init_schema();
    if (db.was_self_healed) {
        db.check_integrity() catch {
            try std.Io.File.stderr().writeStreamingAll(io, "refract: database is corrupted (PRAGMA quick_check failed)\n");
            return error.CorruptDatabase;
        };
    }
    if (profiling) {
        const main_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - main_start;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "refract_profile: main startup db operations total={d}ms\n", .{main_ms}) catch "refract_profile: main startup\n";
        try std.Io.File.stderr().writeStreamingAll(io, msg);
    }

    if (flag_mcp) {
        var needs_index = false;
        {
            var file_count: i64 = 0;
            if (db.prepare("SELECT COUNT(*) FROM files")) |stmt| {
                defer stmt.finalize();
                if (try stmt.step()) file_count = stmt.column_int(0);
            } else |_| {}
            if (file_count == 0) {
                needs_index = true;
            } else {
                // Check if schema migration reset files (mtime=0 means needs re-index)
                var stale_count: i64 = 0;
                if (db.prepare("SELECT COUNT(*) FROM files WHERE mtime=0")) |stmt| {
                    defer stmt.finalize();
                    if (try stmt.step()) stale_count = stmt.column_int(0);
                } else |_| {}
                if (stale_count > 0) needs_index = true;
            }
        }
        if (needs_index) {
            const start_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds();
            try std.Io.File.stderr().writeStreamingAll(io, "refract: auto-indexing workspace for MCP...\n");
            const paths = scanner.scanWithNegations(cwd, alloc, &.{}, &.{}) catch {
                try std.Io.File.stderr().writeStreamingAll(io, "refract: workspace scan failed\n");
                return error.ScanFailed;
            };
            defer {
                for (paths) |p| alloc.free(p);
                alloc.free(paths);
            }
            {
                var scan_buf: [128]u8 = undefined;
                const scan_msg = std.fmt.bufPrint(&scan_buf, "refract: scanned {d} files, indexing...\n", .{paths.len}) catch "refract: scanning complete, indexing...\n";
                try std.Io.File.stderr().writeStreamingAll(io, scan_msg);
            }
            const const_paths = try alloc.alloc([]const u8, paths.len);
            defer alloc.free(const_paths);
            for (paths, 0..) |p, idx| const_paths[idx] = p;
            indexer.reindex(db, const_paths, false, alloc, REINDEX_BUFFER_BYTES, null) catch {
                try std.Io.File.stderr().writeStreamingAll(io, "refract: auto-index failed\n");
                return error.IndexFailed;
            };
            var out_buf: [160]u8 = undefined;
            var indexed_count: i64 = 0;
            if (db.prepare("SELECT COUNT(*) FROM files")) |s| {
                defer s.finalize();
                if (try s.step()) indexed_count = s.column_int(0);
            } else |_| {}
            const elapsed_ms = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds() - start_ms;
            const msg = std.fmt.bufPrint(&out_buf, "refract: indexed {d} files in {d}ms\n", .{ indexed_count, elapsed_ms }) catch "refract: indexing complete\n";
            try std.Io.File.stderr().writeStreamingAll(io, msg);
        }
        // Index stdlib RBS if not already done
        indexStdlibRbs(io, db, cwd, alloc);
        var mcp_server = mcp.Server.init(db, alloc);
        defer mcp_server.deinit();
        var file_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
        var file_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const reader = &file_reader.interface;
        const writer = &file_writer.interface;
        try mcp_server.run(reader, writer);
        return;
    }

    var server = try server_mod.Server.init(io, db, db_pathz, alloc);
    defer server.deinit();
    if (server_log_path) |lp| server.log_path = try alloc.dupe(u8, lp);
    server.log_level.store(server_log_level, .monotonic);
    if (server.tmp_dir) |d| {
        g_tmp_dir = try alloc.dupeZ(u8, d);
    }
    defer if (g_tmp_dir) |d| alloc.free(d);
    server.disable_rubocop.store(server_disable_rubocop, .monotonic);
    server.hot_index_enabled.store(!server_disable_hot_index, .monotonic);
    server.warmup_enabled.store(!server_disable_warmup, .monotonic);
    if (flag_max_workers) |mw| {
        server.max_workers = @intCast(@max(1, @min(mw, 16)));
    }
    if (custom_db_path != null) server.lock_db_path = true;

    var file_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    var file_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const reader = &file_reader.interface;
    const writer = &file_writer.interface;
    server.stdout_writer = writer;

    while (true) {
        if (g_sigterm.load(.acquire)) break;
        const raw = transport.readMessage(reader, alloc) catch |err| switch (err) {
            error.EndOfStream => break,
            error.InvalidContentLength, error.MalformedHeader, error.InvalidHeader => continue,
            else => return err,
        };
        defer alloc.free(raw);

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch {
            const pe = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}";
            server.writer_mutex.lockUncancelable(std.Options.debug_io);
            defer server.writer_mutex.unlock(std.Options.debug_io);
            transport.writeMessage(writer, pe) catch {};
            continue;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const method_val = obj.get("method");
        if (method_val == null) {
            if (obj.get("id") != null) {
                server.handleServerResponse(obj) catch |e| {
                    std.Io.File.stderr().writeStreamingAll(io, @errorName(e)) catch {};
                };
            }
            continue;
        }
        const method = switch (method_val.?) {
            .string => |s| s,
            else => continue,
        };

        const msg = types.RequestMessage{
            .id = obj.get("id"),
            .method = method,
            .params = obj.get("params"),
        };

        crash.recordMessage(method, msg.id);

        const resp = server.dispatch(msg) catch blk: {
            if (msg.id != null) {
                const err_resp = types.ResponseMessage{
                    .id = msg.id,
                    .result = null,
                    .@"error" = .{ .code = @intFromEnum(types.ErrorCode.internal_error), .message = "Internal error" },
                };
                if (buildResponse(alloc, err_resp)) |json_err| {
                    defer alloc.free(json_err);
                    server.writer_mutex.lockUncancelable(std.Options.debug_io);
                    defer server.writer_mutex.unlock(std.Options.debug_io);
                    transport.writeMessage(writer, json_err) catch {};
                } else |_| {}
            }
            break :blk null;
        };
        if (resp) |r| {
            defer if (r.raw_result) |rr| alloc.free(rr);
            const json_resp = try buildResponse(alloc, r);
            defer alloc.free(json_resp);
            server.writer_mutex.lockUncancelable(std.Options.debug_io);
            defer server.writer_mutex.unlock(std.Options.debug_io);
            transport.writeMessage(writer, json_resp) catch |err| {
                if (err == error.BrokenPipe) {
                    server.exit_code = 0;
                    break;
                }
                return err;
            };
        }
        if (server.exit_code != null) break;
    }
    if (g_tmp_dir) |d| std.Io.Dir.cwd().deleteTree(std.Options.debug_io, d) catch {};
}

fn buildResponse(alloc: std.mem.Allocator, resp: types.ResponseMessage) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    const w = &aw.writer;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (resp.id) |id| {
        try writeJsonValue(w, id);
    } else {
        try w.writeAll("null");
    }

    if (resp.@"error") |err| {
        try w.print(",\"error\":{{\"code\":{d},\"message\":", .{err.code});
        try writeJsonString(w, err.message);
        try w.writeByte('}');
    } else {
        try w.writeAll(",\"result\":");
        if (resp.raw_result) |rr| {
            try w.writeAll(rr);
        } else {
            try w.writeAll("null");
        }
    }
    try w.writeByte('}');
    return aw.toOwnedSlice();
}

fn writeJsonValue(w: *std.Io.Writer, val: std.json.Value) !void {
    switch (val) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try writeJsonString(w, s),
        else => try w.writeAll("null"),
    }
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn indexStdlibRbs(io: std.Io, db: db_mod.Db, cwd_path: []const u8, alloc: std.mem.Allocator) void {
    const bundled_count = indexer.indexBundledRbs(db) catch 0;
    if (bundled_count > 0) {
        var bbuf: [128]u8 = undefined;
        const bmsg = std.fmt.bufPrint(&bbuf, "refract: indexed {d} bundled RBS files\n", .{bundled_count}) catch "refract: indexed bundled RBS\n";
        std.debug.print("{s}", .{bmsg});
    }
    var stdlib_count: i64 = 0;
    if (db.prepare("SELECT COUNT(*) FROM files WHERE is_gem=1 AND path NOT LIKE '<bundled>/%'")) |sc| {
        defer sc.finalize();
        if (sc.step() catch false) stdlib_count = sc.column_int(0);
    } else |_| {}
    if (stdlib_count > 0) return;
    const stdlib_paths = gems.findRbsStdlibPaths(io, cwd_path, alloc, 15 * std.time.ns_per_s) catch return;
    defer {
        for (stdlib_paths) |p| alloc.free(p);
        alloc.free(stdlib_paths);
    }
    if (stdlib_paths.len == 0) return;
    const stdlib_const = alloc.alloc([]const u8, stdlib_paths.len) catch return;
    defer alloc.free(stdlib_const);
    for (stdlib_paths, 0..) |p, si| stdlib_const[si] = p;
    indexer.reindex(db, stdlib_const, true, alloc, REINDEX_BUFFER_BYTES, null) catch return;
    var sbuf: [128]u8 = undefined;
    const smsg = std.fmt.bufPrint(&sbuf, "refract: indexed {d} stdlib RBS files\n", .{stdlib_const.len}) catch "refract: indexed stdlib RBS\n";
    std.debug.print("{s}", .{smsg});
}

fn selfExePath(buf: []u8) ?[]const u8 {
    const n = std.c.readlink("/proc/self/exe", buf.ptr, buf.len);
    if (n <= 0 or n >= buf.len) return null;
    return buf[0..@intCast(n)];
}

fn selfTestProbe(io: std.Io, alloc: std.mem.Allocator, label: []const u8, exe_path: []const u8, extra_arg: ?[]const u8, db_path: []const u8, cwd_path: []const u8, request_body: []const u8, expect_substr: []const u8, lsp_framing: bool) bool {
    var stderr = std.Io.File.stderr();

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    argv.append(alloc, exe_path) catch return false;
    if (extra_arg) |a| argv.append(alloc, a) catch return false;
    argv.append(alloc, "--db-path") catch return false;
    argv.append(alloc, db_path) catch return false;

    const cwd_z = alloc.dupeZ(u8, cwd_path) catch return false;
    defer alloc.free(cwd_z);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .cwd = .{ .path = cwd_z },
    }) catch return false;
    defer child.kill(io);

    if (child.stdin) |*sin| {
        if (lsp_framing) {
            var hdr_buf: [128]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{request_body.len}) catch return false;
            sin.writeStreamingAll(io, hdr) catch return false;
            sin.writeStreamingAll(io, request_body) catch return false;
        } else {
            sin.writeStreamingAll(io, request_body) catch return false;
            sin.writeStreamingAll(io, "\n") catch return false;
        }
    }

    var out_buf: [16384]u8 = undefined;
    var got: usize = 0;
    const start = std.Io.Timestamp.now(io, .real).toMilliseconds();
    while (got < out_buf.len) {
        const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
        if (now - start > 5000) break;
        if (child.stdout) |*sout| {
            const n = sout.readStreaming(io, &.{out_buf[got..]}) catch break;
            if (n == 0) break;
            got += n;
            if (std.mem.indexOf(u8, out_buf[0..got], expect_substr) != null) {
                stderr.writeStreamingAll(io, "  ✓ ") catch {};
                stderr.writeStreamingAll(io, label) catch {};
                stderr.writeStreamingAll(io, "\n") catch {};
                return true;
            }
        } else break;
    }
    stderr.writeStreamingAll(io, "  ✗ ") catch {};
    stderr.writeStreamingAll(io, label) catch {};
    stderr.writeStreamingAll(io, " (no expected response within 5s)\n") catch {};
    return false;
}

fn runSelfTest(io: std.Io, alloc: std.mem.Allocator) !void {
    var stderr = std.Io.File.stderr();
    try stderr.writeStreamingAll(io, "refract --self-test\n===================\n");

    var exe_buf: [4096]u8 = undefined;
    const exe_path = selfExePath(&exe_buf) orelse {
        try stderr.writeStreamingAll(io, "  ✗ could not resolve self exe path\n");
        return error.SelfExePath;
    };

    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const rid = std.mem.readInt(u64, &rnd, .little);

    const lsp_db = try std.fmt.allocPrint(alloc, "/tmp/refract_selftest_lsp_{x}.db", .{rid});
    defer alloc.free(lsp_db);
    const mcp_db = try std.fmt.allocPrint(alloc, "/tmp/refract_selftest_mcp_{x}.db", .{rid});
    defer alloc.free(mcp_db);
    const ws = try std.fmt.allocPrint(alloc, "/tmp/refract_selftest_ws_{x}", .{rid});
    defer alloc.free(ws);
    std.Io.Dir.createDirAbsolute(io, ws, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, ws) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, lsp_db) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, mcp_db) catch {};

    const lsp_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":"file:///tmp","capabilities":{},"initializationOptions":{"disableGemIndex":true,"disableRubocop":true}}}
    ;
    const mcp_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"refract-self-test","version":"1"}}}
    ;

    var ok = true;
    if (!selfTestProbe(io, alloc, "LSP initialize handshake", exe_path, null, lsp_db, ws, lsp_req, "\"capabilities\"", true)) ok = false;
    if (!selfTestProbe(io, alloc, "MCP initialize handshake", exe_path, "--mcp", mcp_db, ws, mcp_req, "\"protocolVersion\"", false)) ok = false;

    if (ok) {
        try stderr.writeStreamingAll(io, "self-test OK\n");
    } else {
        try stderr.writeStreamingAll(io, "self-test FAILED\n");
        return error.SelfTestFailed;
    }
}

fn runBenchSorbetSteep(io: std.Io, alloc: std.mem.Allocator, sorbet_root: ?[]const u8, steep_root: ?[]const u8) !void {
    var stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io, "server,method,iter,latency_us\n");
    if (sorbet_root) |root| {
        runOneServer(io, alloc, .sorbet, root, &stdout) catch |err| {
            var ebuf: [256]u8 = undefined;
            const m = std.fmt.bufPrint(&ebuf, "refract: sorbet bench failed: {s}\n", .{@errorName(err)}) catch "refract: sorbet bench failed\n";
            try std.Io.File.stderr().writeStreamingAll(io, m);
        };
    }
    if (steep_root) |root| {
        runOneServer(io, alloc, .steep, root, &stdout) catch |err| {
            var ebuf: [256]u8 = undefined;
            const m = std.fmt.bufPrint(&ebuf, "refract: steep bench failed: {s}\n", .{@errorName(err)}) catch "refract: steep bench failed\n";
            try std.Io.File.stderr().writeStreamingAll(io, m);
        };
    }
}

fn runOneServer(io: std.Io, alloc: std.mem.Allocator, kind: sorbet_harness.ServerKind, root: []const u8, stdout: *std.Io.File) !void {
    var h = try sorbet_harness.Harness.launch(kind, root, alloc);
    defer h.deinit();
    var uri_buf: [1024]u8 = undefined;
    const root_uri = try std.fmt.bufPrint(&uri_buf, "file://{s}", .{root});
    try h.sendInitialize(root_uri);
    const probe_count: u32 = 10;
    var i: u32 = 0;
    while (i < probe_count) : (i += 1) {
        const us = h.measureRequest("textDocument/hover", "{}") catch 0;
        var lbuf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&lbuf, "{s},hover,{d},{d}\n", .{ @tagName(kind), i, us });
        try stdout.writeStreamingAll(io, line);
    }
    h.sendShutdown() catch {};
}

/// Sandbox trampoline. Parses --allow-network / --allow-fs-write=PATH flags,
/// then everything after `--` is the plugin argv. Applies sandbox to current
/// process and execve's the plugin. Filter persists across exec.
fn runSandboxExec(alloc: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    var allow_network = false;
    var allow_fs_write_list = std.ArrayList([]const u8).empty;
    defer allow_fs_write_list.deinit(alloc);

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "--allow-network")) {
            allow_network = true;
        } else if (std.mem.startsWith(u8, a, "--allow-fs-write=")) {
            try allow_fs_write_list.append(alloc, a["--allow-fs-write=".len..]);
        } else {
            try std.Io.File.stderr().writeStreamingAll(io, "refract --sandbox-exec: unknown flag\n");
            std.process.exit(2);
        }
    }
    if (i >= args.len) {
        try std.Io.File.stderr().writeStreamingAll(io, "refract --sandbox-exec: missing plugin entry after --\n");
        std.process.exit(2);
    }

    const config = sandbox.Config{
        .allow_network = allow_network,
        .allow_fs_write = allow_fs_write_list.items,
    };
    sandbox.apply(config) catch |e| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "refract --sandbox-exec: sandbox init failed: {s}\n", .{@errorName(e)}) catch "refract: sandbox init failed\n";
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(3);
    };

    // Build NULL-terminated argv for execve. Entries are already :0 in our
    // args (Zig CLI args are sentinel-terminated), so we can reuse the
    // pointers directly without re-duping.
    const child_argv = args[i..];
    const argv_z = try alloc.alloc(?[*:0]const u8, child_argv.len + 1);
    defer alloc.free(argv_z);
    for (child_argv, 0..) |arg, idx| argv_z[idx] = arg.ptr;
    argv_z[child_argv.len] = null;

    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_z.ptr);
    const envp_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&std.c.environ[0]);
    _ = std.c.execve(child_argv[0].ptr, argv_ptr, envp_ptr);
    // If we reach here, execve failed.
    try std.Io.File.stderr().writeStreamingAll(io, "refract --sandbox-exec: execve failed\n");
    std.process.exit(4);
}

test {
    _ = @import("lsp/transport.zig");
    _ = @import("db.zig");
    _ = @import("indexer/index.zig");
    _ = @import("lsp/hot_index.zig");
    _ = @import("tests/sorbet_harness.zig");
    _ = @import("tests/inline_completion_test.zig");
    _ = @import("tests/dap_test.zig");
    _ = @import("lsp/observability.zig");
    _ = @import("lsp/plugin_host.zig");
    _ = @import("lsp/sandbox.zig");
    _ = @import("lsp/sorbet_bridge.zig");
    _ = @import("lsp/type_resolver.zig");
    _ = @import("dap/server.zig");
    _ = @import("dap/rdbg_bridge.zig");
    _ = @import("indexer/ruby_env.zig");
    _ = @import("indexer/coverage_reader.zig");
    _ = @import("lsp/diagnostics_brakeman.zig");
    _ = @import("lsp/diagnostics_semgrep.zig");
    _ = @import("lsp/test_runner.zig");
    _ = @import("lsp/llm_adapter.zig");
    _ = @import("lsp/otlp_exporter.zig");
    _ = @import("lsp/sorbet_worker.zig");
    _ = @import("lsp/navigation.zig");
    _ = @import("lsp/limits.zig");
}
