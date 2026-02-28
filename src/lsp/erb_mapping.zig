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
    var in_ruby_filter = false;
    var filter_base_indent: u32 = 0;
    var pending_brace_depth: u32 = 0;
    var pending_code_start: u32 = 0;
    var pending_ruby_start: u32 = 0;
    var in_multiline_attrs = false;
    var pending_continuation = false;
    var continuation_code_start: u32 = 0;
    var continuation_ruby_start: u32 = 0;

    while (i < source.len) {
        const line_start = i;
        while (i < source.len and source[i] != '\n') i += 1;
        const line = source[line_start..i];
        if (i < source.len) i += 1;

        const trimmed = std.mem.trimLeft(u8, line, " \t");
        const indent = line.len - trimmed.len;

        if (in_ruby_filter) {
            const filter_name = std.mem.trimLeft(u8, trimmed, ":");
            if (isNonRubyFilter(filter_name)) {
                ruby_offset += 1;
                continue;
            }
            if (trimmed.len > 0 and indent <= filter_base_indent) {
                in_ruby_filter = false;
            } else if (trimmed.len > 0) {
                const code_len: u32 = @intCast(trimmed.len);
                try spans.append(alloc, .{
                    .erb_start = @intCast(line_start + indent),
                    .erb_end = @intCast(line_start + indent + code_len),
                    .ruby_start = ruby_offset,
                    .ruby_end = ruby_offset + code_len,
                });
                ruby_offset += code_len + 1;
                continue;
            }
        }

        if (in_multiline_attrs) {
            var j: usize = 0;
            var in_string: u8 = 0; // 0 = none, '"' or '\'' = inside that quote
            while (j < trimmed.len) : (j += 1) {
                const ch = trimmed[j];
                if (in_string != 0) {
                    if (ch == in_string and (j == 0 or trimmed[j - 1] != '\\')) in_string = 0;
                    continue;
                }
                if (ch == '"' or ch == '\'') {
                    in_string = ch;
                    continue;
                }
                if (ch == '{') pending_brace_depth += 1;
                if (ch == '}') {
                    if (pending_brace_depth > 0) pending_brace_depth -= 1;
                }
            }
            if (pending_brace_depth == 0) {
                const full_code_end: u32 = @intCast(line_start + indent + trimmed.len);
                const full_code_len = full_code_end - pending_code_start;
                if (full_code_len > 0) {
                    try spans.append(alloc, .{
                        .erb_start = pending_code_start,
                        .erb_end = full_code_end,
                        .ruby_start = pending_ruby_start,
                        .ruby_end = pending_ruby_start + full_code_len,
                    });
                }
                ruby_offset += full_code_len + 1;
                in_multiline_attrs = false;
            } else {
                ruby_offset += @as(u32, @intCast(trimmed.len)) + 1;
            }
            continue;
        }

        if (pending_continuation) {
            const prev_code_len = continuation_code_start - continuation_ruby_start;
            const full_code_end: u32 = @intCast(line_start + indent + trimmed.len);
            const full_code_len = full_code_end - continuation_code_start + prev_code_len;

            const line_ends_with_continuation = trimmed.len > 0 and
                (trimmed[trimmed.len - 1] == ',' or trimmed[trimmed.len - 1] == '\\');

            if (line_ends_with_continuation) {
                ruby_offset += @as(u32, @intCast(trimmed.len)) + 1;
                continue;
            } else {
                try spans.append(alloc, .{
                    .erb_start = continuation_code_start,
                    .erb_end = full_code_end,
                    .ruby_start = continuation_ruby_start,
                    .ruby_end = continuation_ruby_start + full_code_len,
                });
                ruby_offset += @as(u32, @intCast(trimmed.len)) + 1;
                pending_continuation = false;
                continue;
            }
        }

        if (trimmed.len >= 2 and trimmed[0] == '-' and trimmed[1] == '#') {
            ruby_offset += 1;
            continue;
        }

        if (trimmed.len > 0 and (trimmed[0] == '=' or trimmed[0] == '-' or trimmed[0] == '!' or trimmed[0] == '&')) {
            var char_idx: usize = 0;
            var skip_count: u32 = 1;

            if (trimmed[0] == '!' and trimmed.len > 1 and trimmed[1] == '=') {
                skip_count = 2;
                char_idx = 2;
            } else if (trimmed[0] == '&' and trimmed.len > 1 and trimmed[1] == '=') {
                skip_count = 2;
                char_idx = 2;
            } else if (trimmed[0] == '=' or trimmed[0] == '-') {
                char_idx = 1;
            } else {
                ruby_offset += 1;
                continue;
            }

            if (char_idx < trimmed.len) {
                while (char_idx < trimmed.len and (trimmed[char_idx] == ' ' or trimmed[char_idx] == '\t')) {
                    skip_count += 1;
                    char_idx += 1;
                }

                const code_start = line_start + indent + skip_count;
                const code_len: u32 = @intCast(trimmed.len - skip_count);
                if (code_len > 0) {
                    const line_ends_with_continuation = trimmed[trimmed.len - 1] == ',' or trimmed[trimmed.len - 1] == '\\';
                    if (line_ends_with_continuation) {
                        pending_continuation = true;
                        continuation_code_start = @intCast(code_start);
                        continuation_ruby_start = ruby_offset;
                        ruby_offset += code_len + 1;
                    } else {
                        try spans.append(alloc, .{
                            .erb_start = @intCast(code_start),
                            .erb_end = @intCast(code_start + code_len),
                            .ruby_start = ruby_offset,
                            .ruby_end = ruby_offset + code_len,
                        });
                        ruby_offset += code_len + 1;
                    }
                } else {
                    ruby_offset += 1;
                }
            } else {
                ruby_offset += 1;
            }
        } else if (trimmed.len > 0 and trimmed[0] == '%') {
            var j: usize = 1;
            while (j < trimmed.len and trimmed[j] != '{' and trimmed[j] != '=' and trimmed[j] != '\n') j += 1;

            if (j < trimmed.len and trimmed[j] == '{') {
                var brace_depth: u32 = 1;
                const brace_start = j + 1;
                j += 1;
                var init_quote: u8 = 0;
                while (j < trimmed.len and brace_depth > 0) : (j += 1) {
                    const bch = trimmed[j];
                    if (init_quote != 0) {
                        if (bch == init_quote and (j == 0 or trimmed[j - 1] != '\\')) init_quote = 0;
                        continue;
                    }
                    if (bch == '"' or bch == '\'') {
                        init_quote = bch;
                        continue;
                    }
                    if (bch == '{') brace_depth += 1;
                    if (bch == '}') brace_depth -= 1;
                }
                if (brace_depth == 0 and brace_start < j - 1) {
                    const code_len: u32 = @intCast(j - brace_start - 1);
                    const code_start = line_start + indent + brace_start;
                    try spans.append(alloc, .{
                        .erb_start = @intCast(code_start),
                        .erb_end = @intCast(code_start + code_len),
                        .ruby_start = ruby_offset,
                        .ruby_end = ruby_offset + code_len,
                    });
                    ruby_offset += code_len + 1;
                } else if (brace_depth > 0) {
                    in_multiline_attrs = true;
                    pending_brace_depth = brace_depth;
                    pending_code_start = @intCast(line_start + indent + brace_start);
                    pending_ruby_start = ruby_offset;
                    ruby_offset += @as(u32, @intCast(trimmed.len - brace_start)) + 1;
                }
            } else if (j < trimmed.len and trimmed[j] == '=') {
                const code_start = line_start + indent + j + 1;
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
        } else if (trimmed.len >= 5 and std.mem.startsWith(u8, trimmed, ":ruby")) {
            in_ruby_filter = true;
            filter_base_indent = @intCast(indent);
            ruby_offset += 1;
        } else if (trimmed.len > 1 and trimmed[0] == ':') {
            if (isNonRubyFilter(trimmed[1..])) {
                ruby_offset += 1;
                continue;
            }
            ruby_offset += 1;
        } else if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') {
            const code_len: u32 = @intCast(trimmed.len - 1);
            if (code_len > 0) {
                const code_start = line_start + indent;
                try spans.append(alloc, .{
                    .erb_start = @intCast(code_start),
                    .erb_end = @intCast(code_start + code_len),
                    .ruby_start = ruby_offset,
                    .ruby_end = ruby_offset + code_len,
                });
            }
            ruby_offset += 1;
        } else {
            ruby_offset += 1;
        }
    }

    return .{
        .spans = try spans.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

pub fn buildSlimMap(alloc: std.mem.Allocator, source: []const u8) !ErbMap {
    var spans = std.ArrayList(ErbSpan){};
    var ruby_buf = std.ArrayList(u8){};
    defer ruby_buf.deinit(alloc);

    var line_start: usize = 0;
    var in_ruby_filter = false;
    var filter_indent: u32 = 0;

    while (line_start < source.len) {
        const line_end = if (std.mem.indexOfScalar(u8, source[line_start..], '\n')) |nl|
            line_start + nl
        else
            source.len;

        const line = source[line_start..line_end];

        var indent: u32 = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}

        const content = if (indent < line.len) line[indent..] else "";

        if (in_ruby_filter) {
            if (content.len > 0 and indent <= filter_indent) {
                in_ruby_filter = false;
            } else if (content.len > 0) {
                const ruby_start: u32 = @intCast(ruby_buf.items.len);
                try ruby_buf.appendSlice(alloc, content);
                try ruby_buf.append(alloc, '\n');
                try spans.append(alloc, .{
                    .erb_start = @intCast(line_start + indent),
                    .erb_end = @intCast(line_end),
                    .ruby_start = ruby_start,
                    .ruby_end = ruby_start + @as(u32, @intCast(content.len)),
                });
                line_start = if (line_end < source.len) line_end + 1 else line_end;
                continue;
            }
        }

        if (content.len == 0) {} else if (content[0] == '/' or content[0] == '|' or content[0] == '\'') {} else if (content[0] == ':') {
            const filter_end = blk: {
                var end: usize = 1;
                while (end < content.len and content[end] != ' ' and content[end] != '\n') : (end += 1) {}
                break :blk end;
            };
            const filter_name = content[1..filter_end];
            if (std.mem.eql(u8, filter_name, "ruby")) {
                in_ruby_filter = true;
                filter_indent = indent;
            }
        } else if (content[0] == '-') {
            if (content.len > 1 and content[1] == ' ') {
                const ruby_code = content[2..];
                const ruby_start: u32 = @intCast(ruby_buf.items.len);
                try ruby_buf.appendSlice(alloc, ruby_code);
                try ruby_buf.append(alloc, '\n');
                try spans.append(alloc, .{
                    .erb_start = @intCast(line_start + indent + 2),
                    .erb_end = @intCast(line_end),
                    .ruby_start = ruby_start,
                    .ruby_end = ruby_start + @as(u32, @intCast(ruby_code.len)),
                });
            }
        } else if (content[0] == '=' or (content.len > 1 and content[0] == '=' and content[1] == '=')) {
            var offset: u32 = 1;
            if (content.len > 1 and content[1] == '=') offset = 2;
            if (offset < content.len and content[offset] == ' ') offset += 1;
            if (offset < content.len) {
                const ruby_code = content[offset..];
                const ruby_start: u32 = @intCast(ruby_buf.items.len);
                try ruby_buf.appendSlice(alloc, ruby_code);
                try ruby_buf.append(alloc, '\n');
                try spans.append(alloc, .{
                    .erb_start = @intCast(line_start + indent + offset),
                    .erb_end = @intCast(line_end),
                    .ruby_start = ruby_start,
                    .ruby_end = ruby_start + @as(u32, @intCast(ruby_code.len)),
                });
            }
        } else {
            if (std.mem.indexOf(u8, content, " = ")) |eq_pos| {
                const ruby_code = content[eq_pos + 3 ..];
                if (ruby_code.len > 0) {
                    const ruby_start: u32 = @intCast(ruby_buf.items.len);
                    try ruby_buf.appendSlice(alloc, ruby_code);
                    try ruby_buf.append(alloc, '\n');
                    try spans.append(alloc, .{
                        .erb_start = @intCast(line_start + indent + @as(u32, @intCast(eq_pos + 3))),
                        .erb_end = @intCast(line_end),
                        .ruby_start = ruby_start,
                        .ruby_end = ruby_start + @as(u32, @intCast(ruby_code.len)),
                    });
                }
            }
        }

        line_start = if (line_end < source.len) line_end + 1 else line_end;
        if (line_start == line_end and line_end >= source.len) break;
    }

    return .{
        .spans = try spans.toOwnedSlice(alloc),
        .alloc = alloc,
    };
}

fn isNonRubyFilter(filter_name: []const u8) bool {
    const non_ruby_filters = [_][]const u8{
        "javascript", "js",
        "css",        "coffeescript",
        "sass",       "scss",
        "plain",      "markdown",
        "md",
    };

    const trimmed = std.mem.trimLeft(u8, filter_name, " \t");
    for (non_ruby_filters) |name| {
        if (std.mem.startsWith(u8, trimmed, name)) {
            return true;
        }
    }
    return false;
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
            !std.mem.endsWith(u8, name, ".html.slim") and
            !std.mem.endsWith(u8, name, ".erb") and
            !std.mem.endsWith(u8, name, ".slim"))
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
    if (std.mem.endsWith(u8, n, ".html.slim")) return n[0 .. n.len - 10];
    if (std.mem.endsWith(u8, n, ".erb")) return n[0 .. n.len - 4];
    if (std.mem.endsWith(u8, n, ".slim")) return n[0 .. n.len - 5];
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

test "haml comment lines skip ruby extraction" {
    const alloc = std.testing.allocator;
    const haml = "-# This is a comment\n= @title\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
}

test "haml != output variant" {
    const alloc = std.testing.allocator;
    const haml = "!= @html\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
    try std.testing.expect(map.spans[0].ruby_end > map.spans[0].ruby_start);
}

test "haml &= output variant" {
    const alloc = std.testing.allocator;
    const haml = "&= @escaped\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
    try std.testing.expect(map.spans[0].ruby_end > map.spans[0].ruby_start);
}

test "haml tag with brace attributes" {
    const alloc = std.testing.allocator;
    const haml = "%div{id: @id, class: @klass}\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
}

test "haml tag with nested braces in attributes" {
    const alloc = std.testing.allocator;
    const haml = "%input{value: {a: 1}, data: {x: 2}}\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
}

test "haml ruby filter block" {
    const alloc = std.testing.allocator;
    const haml = ":ruby\n  if true\n    foo()\n  end\n%p Normal tag\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expect(map.spans.len >= 3);
}

test "haml multiline continuation with pipe" {
    const alloc = std.testing.allocator;
    const haml = "= link_to 'Home', |\n  root_path\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expect(map.spans.len >= 1);
}

test "haml mixed patterns" {
    const alloc = std.testing.allocator;
    const haml = "= @title\n-# comment\n!= @html\n%span{id: @id}\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expect(map.spans.len >= 3);
}

test "haml indented ruby filter" {
    const alloc = std.testing.allocator;
    const haml = ".container\n  :ruby\n    x = 1\n    y = 2\n  %p Done\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expect(map.spans.len >= 2);
}

test "haml multi-line attributes" {
    const alloc = std.testing.allocator;
    const haml = "%div{a: 1,\n  b: 2}\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expect(map.spans.len >= 1);
    const span = map.spans[0];
    const ruby_len = span.ruby_end - span.ruby_start;
    try std.testing.expect(ruby_len >= 8);
}

test "haml multi-line method call" {
    const alloc = std.testing.allocator;
    const haml = "= link_to(\"x\",\n  root_path)\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expect(map.spans.len >= 1);
    const span = map.spans[0];
    const ruby_len = span.ruby_end - span.ruby_start;
    try std.testing.expect(ruby_len >= 10);
}

test "haml javascript filter skip" {
    const alloc = std.testing.allocator;
    const haml = ":javascript\n  alert('hi');\n%p text\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.spans.len);
}

test "haml css filter skip" {
    const alloc = std.testing.allocator;
    const haml = ":css\n  .foo { color: red }\n- x = 1\n";
    var map = try buildHamlMap(alloc, haml);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
    const span = map.spans[0];
    try std.testing.expect(span.ruby_end > span.ruby_start);
}

test "slim = ruby output extraction" {
    const alloc = std.testing.allocator;
    const slim = "= @title\n";
    var map = try buildSlimMap(alloc, slim);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
    const span = map.spans[0];
    try std.testing.expect(span.ruby_end > span.ruby_start);
}

test "slim - ruby code execution" {
    const alloc = std.testing.allocator;
    const slim = "- x = 1\n";
    var map = try buildSlimMap(alloc, slim);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
    const span = map.spans[0];
    try std.testing.expect(span.ruby_end > span.ruby_start);
}

test "slim tag with = ruby" {
    const alloc = std.testing.allocator;
    const slim = "div.class = link_to 'Home', root_path\n";
    var map = try buildSlimMap(alloc, slim);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
    const span = map.spans[0];
    try std.testing.expect(span.ruby_end > span.ruby_start);
}

test "slim :ruby filter block" {
    const alloc = std.testing.allocator;
    const slim = ":ruby\n  if true\n    foo()\n  end\np text\n";
    var map = try buildSlimMap(alloc, slim);
    defer map.deinit();
    try std.testing.expect(map.spans.len >= 2);
}

test "slim / comment skip" {
    const alloc = std.testing.allocator;
    const slim = "/ This is a comment\n= @title\n";
    var map = try buildSlimMap(alloc, slim);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
}

test "slim | plain text skip" {
    const alloc = std.testing.allocator;
    const slim = "| Plain text\n= @value\n";
    var map = try buildSlimMap(alloc, slim);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
}

test "slim == unescaped output" {
    const alloc = std.testing.allocator;
    const slim = "== @html\n";
    var map = try buildSlimMap(alloc, slim);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.spans.len);
    const span = map.spans[0];
    try std.testing.expect(span.ruby_end > span.ruby_start);
}

test "slim empty source" {
    const alloc = std.testing.allocator;
    var map = try buildSlimMap(alloc, "");
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.spans.len);
}

test "slim mixed patterns" {
    const alloc = std.testing.allocator;
    const slim = "= @title\n- x = 1\ndiv = link_to 'Home', root\n/ comment\n| text\n";
    var map = try buildSlimMap(alloc, slim);
    defer map.deinit();
    try std.testing.expect(map.spans.len >= 3);
}
