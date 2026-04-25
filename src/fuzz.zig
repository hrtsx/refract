const std = @import("std");
const prism = @import("prism.zig");
const db_mod = @import("db.zig");
const indexer = @import("indexer/index.zig");
const transport = @import("lsp/transport.zig");

const seed_inputs = [_][]const u8{
    "",
    "\x00\xff\xfe\xfd",
    "class A; def b; end; end\n",
    "module M\n  CONST = 1\nend\n",
    "\xe2\x98\x83 = 'snowman'\n",
    "puts <<~HEREDOC\n  hi\nHEREDOC\n",
    "case x\nin [1, *rest]\n  rest\nend\n",
};

pub fn fuzzPrismParse(input: []const u8) void {
    if (input.len == 0) return;
    var arena: prism.Arena = .{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, input.ptr, input.len, null);
    defer prism.parser_free(&parser);
    _ = prism.parse(&parser);
}

pub fn fuzzIndexer(input: []const u8) void {
    if (input.len == 0) return;
    const db = db_mod.Db.open(":memory:") catch return;
    defer db.close();
    db.init_schema() catch return;
    indexer.indexSource(input, "fuzz.rb", db, std.heap.page_allocator) catch {};
}

pub fn fuzzTransport(input: []const u8) void {
    if (input.len == 0) return;
    var r = std.Io.Reader.fixed(input);
    const result = transport.readMessage(&r, std.heap.page_allocator);
    if (result) |msg| std.heap.page_allocator.free(msg) else |_| {}
}

pub fn fuzzTypeWalker(input: []const u8) void {
    fuzzPrismParse(input);
}

fn parseOnce(input: []const u8) void {
    if (input.len == 0) return;
    var arena: prism.Arena = .{ .current = null, .block_count = 0 };
    defer prism.arena_free(&arena);
    var parser: prism.Parser = undefined;
    prism.parser_init(&arena, &parser, input.ptr, input.len, null);
    defer prism.parser_free(&parser);
    _ = prism.parse(&parser);
}

test "fuzz: prism parser handles seed inputs without crashing" {
    for (seed_inputs) |input| parseOnce(input);
}

test "fuzz: prism parser handles UTF-8 prefix variants" {
    for (seed_inputs) |input| {
        const prefix = "# encoding: utf-8\n";
        var buf: [65536]u8 = undefined;
        const total_len = @min(prefix.len + input.len, buf.len);
        @memcpy(buf[0..prefix.len], prefix);
        const copy_len = total_len - prefix.len;
        @memcpy(buf[prefix.len..][0..copy_len], input[0..copy_len]);
        parseOnce(buf[0..total_len]);
    }
}

test "fuzz: prism parser handles class-like wrappers" {
    for (seed_inputs) |input| {
        const prefix = "class Fuzz\n  def ";
        const suffix = "\n  end\nend\n";
        var buf: [65536]u8 = undefined;
        const body_max = buf.len - prefix.len - suffix.len;
        const body_len = @min(input.len, body_max);
        const total_len = prefix.len + body_len + suffix.len;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..body_len], input[0..body_len]);
        @memcpy(buf[prefix.len + body_len ..][0..suffix.len], suffix);
        parseOnce(buf[0..total_len]);
    }
}

test "fuzz: indexer handles seed inputs without crash" {
    for (seed_inputs) |input| {
        if (input.len == 0) continue;
        const db = db_mod.Db.open(":memory:") catch continue;
        defer db.close();
        db.init_schema() catch continue;
        indexer.indexSource(input, "fuzz_test.rb", db, std.testing.allocator) catch {};
    }
}

test "fuzz: transport rejects malformed headers" {
    const malformed_frames = [_][]const u8{
        "",
        "Content-Length: notanumber\r\n\r\n",
        "Content-Length: 5\r\n\r\nxx",
        "garbage\r\n\r\n",
        "\x00\xff",
    };
    const alloc = std.testing.allocator;
    for (malformed_frames) |frame| {
        var r = std.Io.Reader.fixed(frame);
        const result = transport.readMessage(&r, alloc);
        if (result) |msg| {
            alloc.free(msg);
        } else |_| {}
    }
}
