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
        .flags = &.{ "-DSQLITE_OMIT_LOAD_EXTENSION=1", "-w" },
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

    const zon_bytes: []const u8 = @embedFile("build.zig.zon");
    const ver_prefix = ".version = \"";
    const vs = (std.mem.indexOf(u8, zon_bytes, ver_prefix) orelse
        @panic("build.zig.zon missing .version")) + ver_prefix.len;
    const ve = std.mem.indexOfPos(u8, zon_bytes, vs, "\"") orelse
        @panic("build.zig.zon malformed .version");
    const version_str = zon_bytes[vs..ve];
    const meta = b.addOptions();
    meta.addOption([]const u8, "version", version_str);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVendorDeps(b, exe_mod);
    exe_mod.addOptions("build_meta", meta);

    const exe = b.addExecutable(.{
        .name = "refract",
        .root_module = exe_mod,
    });
    if (optimize != .Debug) exe_mod.strip = true;
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

    // Benchmarks — linked against source, not subprocess
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVendorDeps(b, bench_mod);
    const bench_tests = b.addTest(.{ .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_tests);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Fuzz harness — linked against source
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    addVendorDeps(b, fuzz_mod);
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    fuzz_step.dependOn(&run_fuzz.step);

    // Protocol integration tests — spawn the built binary via subprocess
    const proto_opts = b.addOptions();
    const refract_bin_path = b.getInstallPath(.bin, exe.name);
    proto_opts.addOption([]const u8, "refract_bin", refract_bin_path);

    const harness_mod = b.createModule(.{
        .root_source_file = b.path("src/tests/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    harness_mod.addOptions("build_opts", proto_opts);

    const proto_test_files = .{
        .{ "src/tests/protocol_test.zig", "test:lsp" },
        .{ "src/tests/mcp_test.zig", "test:mcp" },
        .{ "src/tests/edge_case_test.zig", "test:edge" },
    };

    inline for (proto_test_files) |entry| {
        const mod = b.createModule(.{
            .root_source_file = b.path(entry[0]),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("harness", harness_mod);
        const t = b.addTest(.{ .root_module = mod });
        t.step.dependOn(b.getInstallStep());
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        const named_step = b.step(entry[1], "Run " ++ entry[1]);
        named_step.dependOn(&run_t.step);
    }
}
