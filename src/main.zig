const std = @import("std");
const build_meta = @import("build_meta");
const db_mod = @import("db.zig");
const transport = @import("lsp/transport.zig");
const types = @import("lsp/types.zig");
const server_mod = @import("lsp/server.zig");
const mcp = @import("mcp/server.zig");
const indexer = @import("indexer/index.zig");
const scanner = @import("indexer/scanner.zig");
const gems = @import("indexer/gems.zig");

var stdin_buf: [65536]u8 = undefined;
var stdout_buf: [65536]u8 = undefined;

var g_sigterm = std.atomic.Value(bool).init(false);
var g_tmp_dir: ?[:0]u8 = null;

fn onSigterm(_: std.posix.SIG) callconv(.c) void {
    g_sigterm.store(true, .seq_cst);
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const io = init.io;

    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const args = try init.minimal.args.toSlice(args_arena.allocator());

    var server_log_path: ?[]const u8 = null;
    var server_log_level: u8 = 2;
    var server_disable_rubocop: bool = false;
    var custom_db_path: ?[]const u8 = null;
    var flag_reset_db: bool = false;
    var flag_print_db_path: bool = false;
    var flag_check: bool = false;
    var flag_stats: bool = false;
    var flag_mcp: bool = false;
    var flag_index_only: bool = false;
    var flag_warm_stdlib: bool = false;
    var flag_dump_symbols: bool = false;
    var flag_workspace_info: bool = false;
    var flag_max_workers: ?u32 = null;
    var flag_json: bool = false;

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
                    "  --mcp                Run as MCP server\n",
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
        } else if (std.mem.eql(u8, arg, "--index-only")) {
            flag_index_only = true;
        } else if (std.mem.eql(u8, arg, "--warm-stdlib")) {
            flag_warm_stdlib = true;
        } else if (std.mem.eql(u8, arg, "--dump-symbols")) {
            flag_dump_symbols = true;
        } else if (std.mem.eql(u8, arg, "--workspace-info")) {
            flag_workspace_info = true;
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

        indexer.reindex(index_db, const_paths, false, alloc, 8 * 1024 * 1024, null) catch {
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

        var schema_ver: []const u8 = "unknown";
        if (info_db.prepare("SELECT value FROM meta WHERE key='schema_version'")) |stmt| {
            defer stmt.finalize();
            if (try stmt.step()) schema_ver = stmt.column_text(0);
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

    const db = db_mod.Db.open(db_pathz) catch {
        try std.Io.File.stderr().writeStreamingAll(io, "refract: failed to open database\n");
        return error.DatabaseOpen;
    };
    defer {
        db.checkpoint();
        db.close();
    }
    try db.init_schema();
    db.check_integrity() catch {
        try std.Io.File.stderr().writeStreamingAll(io, "refract: database is corrupted (PRAGMA quick_check failed)\n");
        return error.CorruptDatabase;
    };

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
            indexer.reindex(db, const_paths, false, alloc, 8 * 1024 * 1024, null) catch {
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
            try transport.writeMessage(writer, json_resp);
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
    indexer.reindex(db, stdlib_const, true, alloc, 8 * 1024 * 1024, null) catch return;
    var sbuf: [128]u8 = undefined;
    const smsg = std.fmt.bufPrint(&sbuf, "refract: indexed {d} stdlib RBS files\n", .{stdlib_const.len}) catch "refract: indexed stdlib RBS\n";
    std.debug.print("{s}", .{smsg});
}

test {
    _ = @import("lsp/transport.zig");
    _ = @import("db.zig");
    _ = @import("indexer/index.zig");
}
