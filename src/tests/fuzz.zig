const std = @import("std");
const prism = @import("../prism.zig");
const db_mod = @import("../db.zig");
const indexer = @import("../indexer/index.zig");
const transport = @import("../lsp/transport.zig");

test "fuzz: prism parser handles arbitrary input" {
    const input = std.testing.fuzzInput(.{});
    if (input.len == 0) return;

    var arena: prism.Arena = .{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, input.ptr, input.len, null);
    defer prism.parser_free(&parser);
    _ = prism.parse(&parser);
}

test "fuzz: prism parser handles UTF-8 variants" {
    const input = std.testing.fuzzInput(.{});
    if (input.len == 0) return;

    const prefix = "# encoding: utf-8\n";
    var buf: [65536]u8 = undefined;
    const total_len = @min(prefix.len + input.len, buf.len);
    @memcpy(buf[0..prefix.len], prefix);
    const copy_len = total_len - prefix.len;
    @memcpy(buf[prefix.len..][0..copy_len], input[0..copy_len]);

    var arena: prism.Arena = .{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, &buf, total_len, null);
    defer prism.parser_free(&parser);
    _ = prism.parse(&parser);
}

test "fuzz: prism parser handles class-like structures" {
    const input = std.testing.fuzzInput(.{});
    if (input.len == 0) return;

    const prefix = "class Fuzz\n  def ";
    const suffix = "\n  end\nend\n";
    var buf: [65536]u8 = undefined;
    const body_max = buf.len - prefix.len - suffix.len;
    const body_len = @min(input.len, body_max);
    const total_len = prefix.len + body_len + suffix.len;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..body_len], input[0..body_len]);
    @memcpy(buf[prefix.len + body_len ..][0..suffix.len], suffix);

    var arena: prism.Arena = .{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, &buf, total_len, null);
    defer prism.parser_free(&parser);
    _ = prism.parse(&parser);
}

test "fuzz: indexer handles arbitrary Ruby source without crash" {
    const input = std.testing.fuzzInput(.{});
    if (input.len == 0) return;

    const db = db_mod.Db.open(":memory:") catch return;
    defer db.close();
    db.init_schema() catch return;

    indexer.indexSource(input, "fuzz_test.rb", db, std.testing.allocator) catch {};
}

test "fuzz: transport rejects malformed headers" {
    const input = std.testing.fuzzInput(.{});
    if (input.len == 0) return;

    var stream = std.io.fixedBufferStream(input);
    const alloc = std.testing.allocator;
    const result = transport.readMessage(stream.reader(), alloc);
    if (result) |msg| {
        alloc.free(msg);
    } else |_| {}
}
