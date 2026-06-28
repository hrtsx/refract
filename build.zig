const std = @import("std");

const prism_sources = [_][]const u8{
    "prism.c",
    "diagnostic.c",
    "encoding.c",
    "node.c",
    "options.c",
    "prettyprint.c",
    "regexp.c",
    "serialize.c",
    "static_literals.c",
    "token_type.c",
    "util/pm_arena.c",
    "util/pm_buffer.c",
    "util/pm_char.c",
    "util/pm_constant_pool.c",
    "util/pm_integer.c",
    "util/pm_line_offset_list.c",
    "util/pm_list.c",
    "util/pm_memchr.c",
    "util/pm_string.c",
    "util/pm_strncasecmp.c",
    "util/pm_strpbrk.c",
};

fn addVendorDeps(b: *std.Build, m: *std.Build.Module) void {
    m.link_libc = true;
    m.addCSourceFiles(.{
        .root = b.path("vendor/prism/src"),
        .files = &prism_sources,
        .flags = &.{"-w"},
    });
    m.addIncludePath(b.path("vendor/prism/include"));
    m.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_OMIT_LOAD_EXTENSION=1", "-DSQLITE_ENABLE_FTS5=1", "-w" },
    });
    m.addCSourceFile(.{
        .file = b.path("vendor/sqlite/bind_helpers.c"),
        .flags = &.{"-w"},
    });
    m.addIncludePath(b.path("vendor/sqlite"));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // A flagless `zig build` leaves `optimize == .Debug`, which silently produces a
    // ~93 MB unoptimized binary — benchmarking it fakes a ~5–6× slowdown. Default the
    // *shipped executable* to ReleaseSafe in that case; tests/bench/fuzz keep the fast
    // Debug default. Any explicit `-Doptimize=…` or `--release=…` still wins.
    const exe_optimize: std.builtin.OptimizeMode =
        if (optimize == .Debug and !b.user_input_options.contains("optimize")) .ReleaseSafe else optimize;

    const zon_bytes: []const u8 = @embedFile("build.zig.zon");
    const ver_prefix = ".version = \"";
    const vs = (std.mem.indexOf(u8, zon_bytes, ver_prefix) orelse
        @panic("build.zig.zon missing .version")) + ver_prefix.len;
    const ve = std.mem.indexOfPos(u8, zon_bytes, vs, "\"") orelse
        @panic("build.zig.zon malformed .version");
    const version_str = zon_bytes[vs..ve];
    const meta = b.addOptions();
    meta.addOption([]const u8, "version", version_str);

    const git_sha = b.option([]const u8, "git_sha", "Short git SHA of the build") orelse "unknown";
    meta.addOption([]const u8, "git_sha", git_sha);

    var zig_ver_buf: [32]u8 = undefined;
    const zv = @import("builtin").zig_version;
    const zig_version_str = std.fmt.bufPrint(&zig_ver_buf, "{d}.{d}.{d}", .{ zv.major, zv.minor, zv.patch }) catch "unknown";
    meta.addOption([]const u8, "zig_version", b.allocator.dupe(u8, zig_version_str) catch "unknown");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = exe_optimize,
    });
    addVendorDeps(b, exe_mod);
    exe_mod.addOptions("build_meta", meta);

    const exe = b.addExecutable(.{
        .name = "refract",
        .root_module = exe_mod,
    });
    if (exe_optimize != .Debug) exe_mod.strip = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVendorDeps(b, test_mod);
    test_mod.addOptions("build_meta", meta);

    const exe_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    const test_unit_step = b.step("test:unit", "Run unit tests reachable from main.zig only (no subprocess protocol tests)");
    test_unit_step.dependOn(&run_tests.step);

    // Benchmarks — linked against source, not subprocess
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVendorDeps(b, bench_mod);
    const bench_tests = b.addTest(.{ .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_tests);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // LSP head-to-head bench: drives refract/solargraph/ruby-lsp via JSON-RPC,
    // captures perf + accuracy into bench-results/<ts>-<sha>.json,
    // prints a delta vs the previous snapshot. See docs/BENCHMARK.md.
    const bench_lsp_cmd = b.addSystemCommand(&.{"scripts/bench/snapshot.sh"});
    bench_lsp_cmd.step.dependOn(b.getInstallStep());
    const bench_lsp_step = b.step("bench-lsp", "Run head-to-head LSP benchmark vs solargraph + ruby-lsp");
    bench_lsp_step.dependOn(&bench_lsp_cmd.step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVendorDeps(b, fuzz_mod);
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    fuzz_step.dependOn(&run_fuzz.step);

    const fuzz_bin_mod = b.createModule(.{
        .root_source_file = b.path("src/libfuzzer.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVendorDeps(b, fuzz_bin_mod);
    const fuzz_bin = b.addExecutable(.{
        .name = "refract-fuzz",
        .root_module = fuzz_bin_mod,
    });
    const install_fuzz_bin = b.addInstallArtifact(fuzz_bin, .{});
    const fuzz_bin_step = b.step("fuzz-bin", "Build the libFuzzer-style entry binary (refract-fuzz)");
    fuzz_bin_step.dependOn(&install_fuzz_bin.step);

    const fuzz_corpus_step = b.step("fuzz-corpus", "Drive refract-fuzz against every file under fuzzing/");
    const corpus_dirs = [_][]const u8{
        "fuzzing/parser",
        "fuzzing/indexer",
        "fuzzing/transport",
        "fuzzing/typewalker",
    };
    const build_io = b.graph.io;
    for (corpus_dirs) |dir_rel| {
        var dir = b.build_root.handle.openDir(build_io, dir_rel, .{ .iterate = true }) catch continue;
        defer dir.close(build_io);
        var it = dir.iterate();
        while (it.next(build_io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const file_rel = b.fmt("{s}/{s}", .{ dir_rel, entry.name });
            const run = b.addRunArtifact(fuzz_bin);
            run.setStdIn(.{ .lazy_path = b.path(file_rel) });
            run.expectExitCode(0);
            fuzz_corpus_step.dependOn(&run.step);
        }
    }

    // Protocol integration tests — spawn the built binary via subprocess
    const proto_opts = b.addOptions();
    const refract_bin_path = b.getInstallPath(.bin, exe.name);
    proto_opts.addOption([]const u8, "refract_bin", refract_bin_path);

    const harness_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/harness.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    harness_mod.addOptions("build_opts", proto_opts);

    const proto_test_files = .{
        .{ "src/tests/lsp/lifecycle_test.zig", "test:lsp-lifecycle" },
        .{ "src/tests/lsp/completion_test.zig", "test:lsp-completion" },
        .{ "src/tests/lsp/hover_test.zig", "test:lsp-hover" },
        .{ "src/tests/lsp/navigation_test.zig", "test:lsp-navigation" },
        .{ "src/tests/lsp/rename_test.zig", "test:lsp-rename" },
        .{ "src/tests/lsp/types_test.zig", "test:lsp-types" },
        .{ "src/tests/lsp/types2_test.zig", "test:lsp-types2" },
        .{ "src/tests/lsp/diagnostics_test.zig", "test:lsp-diagnostics" },
        .{ "src/tests/lsp/indexing_test.zig", "test:lsp-indexing" },
        .{ "src/tests/lsp/indexing2_test.zig", "test:lsp-indexing2" },
        .{ "src/tests/lsp/editing_test.zig", "test:lsp-editing" },
        .{ "src/tests/lsp/cli_config_test.zig", "test:lsp-cli" },
        .{ "src/tests/lsp/robustness_test.zig", "test:lsp-robustness" },
        .{ "src/tests/lsp/misc_test.zig", "test:lsp-misc" },
        .{ "src/tests/mcp_test.zig", "test:mcp" },
        .{ "src/tests/edge_case_test.zig", "test:edge" },
        .{ "src/tests/navigation_hierarchy_test.zig", "test:nav" },
        .{ "src/tests/concurrency_stress_test.zig", "test:stress" },
    };

    const test_lsp_step = b.step("test:lsp", "Run all LSP protocol tests");

    // Each protocol test binary spawns refract subprocesses. Running all of them in
    // parallel storms the host with refract children that contend on stdout pipes and
    // DB locks — the ~50% macOS-CI flake (truncated stdout → NoSymbolResponse). Chain
    // the aggregate `test` run steps so the binaries execute sequentially (≤1 refract
    // child at a time). The fast per-binary named steps (test:lsp-completion, …) stay
    // independent for targeted runs.
    var prev_run: ?*std.Build.Step = null;
    inline for (proto_test_files) |entry| {
        const mod = b.createModule(.{
            .root_source_file = b.path(entry[0]),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addImport("harness", harness_mod);
        const t = b.addTest(.{ .root_module = mod });
        t.step.dependOn(b.getInstallStep());
        const run_t = b.addRunArtifact(t);
        if (prev_run) |p| run_t.step.dependOn(p);
        prev_run = &run_t.step;
        test_step.dependOn(&run_t.step);
        const named_step = b.step(entry[1], "Run " ++ entry[1]);
        named_step.dependOn(&run_t.step);
        if (comptime std.mem.startsWith(u8, entry[1], "test:lsp-")) {
            test_lsp_step.dependOn(&run_t.step);
        }
    }
}
