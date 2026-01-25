const std = @import("std");

pub const ErbSpan = struct {
    erb_start: u32,
    erb_end: u32,
    ruby_start: u32,
    ruby_end: u32,
};

pub const ErbMap = struct {
    spans: []const ErbSpan,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *ErbMap) void {
        self.alloc.free(self.spans);
    }

    pub fn erbToRuby(self: *const ErbMap, erb_offset: u32) ?u32 {
        for (self.spans) |span| {
            if (erb_offset >= span.erb_start and erb_offset < span.erb_end) {
                return span.ruby_start + (erb_offset - span.erb_start);
            }
        }
        return null;
    }

    pub fn rubyToErb(self: *const ErbMap, ruby_offset: u32) ?u32 {
        for (self.spans) |span| {
            if (ruby_offset >= span.ruby_start and ruby_offset < span.ruby_end) {
                return span.erb_start + (ruby_offset - span.ruby_start);
            }
        }
        return null;
    }

};

pub fn buildMap(alloc: std.mem.Allocator, source: []const u8) !ErbMap {
    var spans = std.ArrayList(ErbSpan){};
    var i: usize = 0;
    var ruby_offset: u32 = 0;
    var in_ruby = false;
    var is_comment = false;
    var erb_code_start: u32 = 0;

    while (i < source.len) {
        if (!in_ruby) {
            if (i + 1 < source.len and source[i] == '<' and source[i + 1] == '%') {
                if (i + 2 < source.len and source[i + 2] == '%') {
                    ruby_offset += 3;
                    i += 3;
                    continue;
                }
                var skip: u32 = 2;
                i += 2;
                if (i < source.len) switch (source[i]) {
                    '#' => {
                        is_comment = true;
                        skip += 1;
                        i += 1;
                    },
                    '=', '-' => {
                        skip += 1;
                        i += 1;
                    },
                    else => {},
                };
                ruby_offset += skip;
                erb_code_start = @intCast(i);
                in_ruby = true;
                continue;
            }
            if (source[i] == '\n') {
                ruby_offset += 1;
            } else {
                ruby_offset += 1;
            }
            i += 1;
        } else {
            if (i + 1 < source.len and source[i] == '%' and source[i + 1] == '>') {
                if (!is_comment) {
                    const erb_end: u32 = @intCast(i);
                    const code_len = erb_end - erb_code_start;
                    if (code_len > 0) {
                        try spans.append(alloc, .{
                            .erb_start = erb_code_start,
                            .erb_end = erb_end,
                            .ruby_start = ruby_offset - code_len,
                            .ruby_end = ruby_offset,
                        });
                    }
                }
                ruby_offset += 2;
                i += 2;
                if (i < source.len and source[i] == '-') {
                    ruby_offset += 1;
                    i += 1;
                }
                in_ruby = false;
                is_comment = false;
                continue;
            }
            if (is_comment) {
                ruby_offset += 1;
            } else {
                ruby_offset += 1;
            }
            i += 1;
        }
    }

    return .{
        .spans = try spans.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

pub fn buildHamlMap(alloc: std.mem.Allocator, source: []const u8) !ErbMap {
    var spans = std.ArrayList(ErbSpan){};
    var i: usize = 0;
    var ruby_offset: u32 = 0;

    while (i < source.len) {
        const line_start = i;
        while (i < source.len and source[i] != '\n') i += 1;
        const line = source[line_start..i];
        if (i < source.len) i += 1;

        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len > 0 and (trimmed[0] == '=' or trimmed[0] == '-')) {
            const code_start = line_start + (line.len - trimmed.len) + 1;
            const code_len: u32 = @intCast(trimmed.len - 1);
            if (code_len > 0) {
                try spans.append(alloc, .{
                    .erb_start = @intCast(code_start),
                    .erb_end = @intCast(code_start + code_len),
                    .ruby_start = ruby_offset,
                    .ruby_end = ruby_offset + code_len,
                });
            }
            ruby_offset += code_len + 1;
        } else if (trimmed.len > 0 and trimmed[0] == '%') {
            var j: usize = 1;
            while (j < trimmed.len and trimmed[j] != '=' and trimmed[j] != '\n') j += 1;
            if (j < trimmed.len and trimmed[j] == '=') {
                const code_start = line_start + (line.len - trimmed.len) + j + 1;
                const code_len: u32 = @intCast(trimmed.len - j - 1);
                if (code_len > 0) {
                    try spans.append(alloc, .{
                        .erb_start = @intCast(code_start),
                        .erb_end = @intCast(code_start + code_len),
                        .ruby_start = ruby_offset,
                        .ruby_end = ruby_offset + code_len,
                    });
                }
                ruby_offset += code_len + 1;
            } else {
                ruby_offset += 1;
            }
        } else {
            ruby_offset += 1;
        }
    }

    return .{
        .spans = try spans.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

pub fn isErbRubyContext(source: []const u8, offset: usize) bool {
    if (offset >= source.len) return false;
    var i: usize = offset;
    while (i > 0) : (i -= 1) {
        if (i + 1 < source.len and source[i - 1] == '<' and source[i] == '%') return true;
        if (i + 1 < source.len and source[i - 1] == '%' and source[i] == '>') return false;
        if (source[i] == '\n') break;
    }
    return false;
}

pub fn isErbHtmlContext(source: []const u8, offset: usize) bool {
    return !isErbRubyContext(source, offset);
}

pub const ViewHelper = struct {
    name: []const u8,
    snippet: []const u8,
    detail: []const u8,
};

pub const RAILS_VIEW_HELPERS = [_]ViewHelper{
    .{ .name = "link_to", .snippet = "link_to ${1:name}, ${2:url}", .detail = "link_to(name, url, options)" },
    .{ .name = "form_with", .snippet = "form_with model: ${1:model} do |${2:f}|\\n  $0\\nend", .detail = "form_with(model:, url:, ...)" },
    .{ .name = "image_tag", .snippet = "image_tag ${1:source}", .detail = "image_tag(source, options)" },
    .{ .name = "render", .snippet = "render ${1:partial}", .detail = "render(partial, locals)" },
    .{ .name = "content_tag", .snippet = "content_tag :${1:tag}, ${2:content}", .detail = "content_tag(name, content, options)" },
    .{ .name = "button_to", .snippet = "button_to ${1:name}, ${2:url}", .detail = "button_to(name, url, options)" },
    .{ .name = "form_for", .snippet = "form_for ${1:model} do |${2:f}|\\n  $0\\nend", .detail = "form_for(record, options)" },
    .{ .name = "stylesheet_link_tag", .snippet = "stylesheet_link_tag ${1:source}", .detail = "stylesheet_link_tag(*sources)" },
    .{ .name = "javascript_include_tag", .snippet = "javascript_include_tag ${1:source}", .detail = "javascript_include_tag(*sources)" },
    .{ .name = "csrf_meta_tags", .snippet = "csrf_meta_tags", .detail = "csrf_meta_tags" },
    .{ .name = "yield", .snippet = "yield ${1::content}", .detail = "yield(name = nil)" },
    .{ .name = "content_for", .snippet = "content_for :${1:name} do\\n  $0\\nend", .detail = "content_for(name, &block)" },
    .{ .name = "turbo_frame_tag", .snippet = "turbo_frame_tag ${1:id} do\\n  $0\\nend", .detail = "turbo_frame_tag(id, &block)" },
    .{ .name = "turbo_stream_from", .snippet = "turbo_stream_from ${1:streamable}", .detail = "turbo_stream_from(*streamables)" },
    .{ .name = "tag", .snippet = "tag.${1:div} ${2:content}", .detail = "tag.element(content, options)" },
    .{ .name = "simple_format", .snippet = "simple_format ${1:text}", .detail = "simple_format(text, options)" },
    .{ .name = "truncate", .snippet = "truncate ${1:text}, length: ${2:30}", .detail = "truncate(text, options)" },
    .{ .name = "number_to_currency", .snippet = "number_to_currency ${1:number}", .detail = "number_to_currency(number, options)" },
    .{ .name = "time_ago_in_words", .snippet = "time_ago_in_words ${1:from_time}", .detail = "time_ago_in_words(from_time)" },
    .{ .name = "distance_of_time_in_words", .snippet = "distance_of_time_in_words ${1:from}, ${2:to}", .detail = "distance_of_time_in_words(from, to)" },
    .{ .name = "pluralize", .snippet = "pluralize ${1:count}, ${2:singular}", .detail = "pluralize(count, singular, plural)" },
};

pub fn scanPartials(root_path: []const u8, alloc: std.mem.Allocator) ![][]u8 {
    var results = std.ArrayList([]u8){};
    const views_path = std.fmt.allocPrint(alloc, "{s}/app/views", .{root_path}) catch return results.toOwnedSlice(alloc);
    defer alloc.free(views_path);

    var dir = std.fs.openDirAbsolute(views_path, .{ .iterate = true }) catch
        return results.toOwnedSlice(alloc);
    defer dir.close();

    var walker = dir.walk(alloc) catch return results.toOwnedSlice(alloc);
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.basename;
        if (name.len < 2 or name[0] != '_') continue;
        if (!std.mem.endsWith(u8, name, ".html.erb") and
            !std.mem.endsWith(u8, name, ".html.haml") and
            !std.mem.endsWith(u8, name, ".erb"))
            continue;
        const stripped = stripPartialName(name);
        if (stripped.len == 0) continue;
        const dir_path = std.fs.path.dirname(entry.path) orelse "";
        const partial_path = if (dir_path.len > 0)
            std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, stripped }) catch continue
        else
            alloc.dupe(u8, stripped) catch continue;
        results.append(alloc, partial_path) catch {
            alloc.free(partial_path);
            continue;
        };
    }

    return results.toOwnedSlice(alloc);
}

fn stripPartialName(name: []const u8) []const u8 {
    var n = name;
    if (n.len > 0 and n[0] == '_') n = n[1..];
    if (std.mem.endsWith(u8, n, ".html.erb")) return n[0 .. n.len - 9];
    if (std.mem.endsWith(u8, n, ".html.haml")) return n[0 .. n.len - 10];
    if (std.mem.endsWith(u8, n, ".erb")) return n[0 .. n.len - 4];
    return n;
}

test "erb offset mapping round-trip" {
    const alloc = std.testing.allocator;
    const erb_src = "<h1><%= @title %></h1>";
    var map = try buildMap(alloc, erb_src);
    defer map.deinit();

    try std.testing.expect(map.spans.len > 0);
    const first = map.spans[0];
    try std.testing.expect(first.erb_start == 7);
    try std.testing.expect(first.erb_end == 15);
}

test "erb ruby context detection" {
    const src = "<h1><%= @title %></h1>";
    try std.testing.expect(isErbRubyContext(src, 8));
    try std.testing.expect(isErbHtmlContext(src, 1));
}

test "erb map reverse translation" {
    const alloc = std.testing.allocator;
    const erb_src = "<p><%= foo %></p><%= bar %>";
    var map = try buildMap(alloc, erb_src);
    defer map.deinit();

    for (map.spans) |span| {
        const rb = span.ruby_start;
        const back = map.rubyToErb(rb);
        try std.testing.expect(back != null);
        try std.testing.expectEqual(span.erb_start, back.?);
    }
}

test "haml map builds spans" {
    const alloc = std.testing.allocator;
    const haml = "= link_to 'Home', root_path\n%p= @name\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expect(map.spans.len >= 1);
}

test "strip partial name" {
    try std.testing.expectEqualStrings("header", stripPartialName("_header.html.erb"));
    try std.testing.expectEqualStrings("sidebar", stripPartialName("_sidebar.html.haml"));
    try std.testing.expectEqualStrings("form", stripPartialName("_form.erb"));
}

test "isErbRubyContext multiple blocks" {
    const src = "<%= a %> text <%= b %>";
    try std.testing.expect(isErbRubyContext(src, 5));
    try std.testing.expect(isErbHtmlContext(src, 10));
    try std.testing.expect(isErbRubyContext(src, 17));
}

test "empty erb source" {
    const alloc = std.testing.allocator;
    var map = try buildMap(alloc, "");
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.spans.len);
}

test "erb comment blocks produce no spans" {
    const alloc = std.testing.allocator;
    const src = "<%# this is a comment %><%= code %>";
    var map = try buildMap(alloc, src);
    defer map.deinit();
    try std.testing.expect(map.spans.len == 1);
}

test "erb escaped tag produces no spans" {
    const alloc = std.testing.allocator;
    const src = "<%% literal %>";
    var map = try buildMap(alloc, src);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.spans.len);
}

test "erbToRuby returns null for html offsets" {
    const alloc = std.testing.allocator;
    const src = "<h1><%= x %></h1>";
    var map = try buildMap(alloc, src);
    defer map.deinit();
    try std.testing.expect(map.erbToRuby(0) == null);
    try std.testing.expect(map.erbToRuby(1) == null);
}

test "haml empty source" {
    const alloc = std.testing.allocator;
    var map = try buildHamlMap(alloc, "");
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.spans.len);
}

test "haml plain text line" {
    const alloc = std.testing.allocator;
    var map = try buildHamlMap(alloc, "Hello world\n");
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.spans.len);
}

test "view helpers list is populated" {
    try std.testing.expect(RAILS_VIEW_HELPERS.len > 10);
}

test "erb dash closing tag" {
    const alloc = std.testing.allocator;
    const src = "<%= foo -%>";
    var map = try buildMap(alloc, src);
    defer map.deinit();
    try std.testing.expect(map.spans.len == 1);
}
