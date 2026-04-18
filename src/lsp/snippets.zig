const std = @import("std");

pub const Snippet = struct {
    trigger: []const u8,
    label: []const u8,
    body: []const u8,
    detail: []const u8,
    sort_prefix: []const u8 = "zz_",
};

pub const RUBY_SNIPPETS = [_]Snippet{
    .{
        .trigger = "def_init",
        .label = "def initialize",
        .body = "def initialize(${1:params})\\n  $0\\nend",
        .detail = "Initialize method",
    },
    .{
        .trigger = "def",
        .label = "def method",
        .body = "def ${1:method_name}(${2:params})\\n  $0\\nend",
        .detail = "Method definition",
    },
    .{
        .trigger = "defs",
        .label = "def self.method",
        .body = "def self.${1:method_name}(${2:params})\\n  $0\\nend",
        .detail = "Class method definition",
    },
    .{
        .trigger = "attr",
        .label = "attr_accessor",
        .body = "attr_accessor :${1:name}",
        .detail = "Attribute accessor",
    },
    .{
        .trigger = "attr_r",
        .label = "attr_reader",
        .body = "attr_reader :${1:name}",
        .detail = "Attribute reader",
    },
    .{
        .trigger = "attr_w",
        .label = "attr_writer",
        .body = "attr_writer :${1:name}",
        .detail = "Attribute writer",
    },
    .{
        .trigger = "class",
        .label = "class definition",
        .body = "class ${1:ClassName}\\n  $0\\nend",
        .detail = "Class definition",
    },
    .{
        .trigger = "module",
        .label = "module definition",
        .body = "module ${1:ModuleName}\\n  $0\\nend",
        .detail = "Module definition",
    },
    .{
        .trigger = "do",
        .label = "do block",
        .body = "do |${1:var}|\\n  $0\\nend",
        .detail = "Block with do...end",
    },
    .{
        .trigger = "if",
        .label = "if statement",
        .body = "if ${1:condition}\\n  $0\\nend",
        .detail = "Conditional",
    },
    .{
        .trigger = "ife",
        .label = "if/else",
        .body = "if ${1:condition}\\n  $2\\nelse\\n  $0\\nend",
        .detail = "If/else conditional",
    },
    .{
        .trigger = "unless",
        .label = "unless statement",
        .body = "unless ${1:condition}\\n  $0\\nend",
        .detail = "Unless conditional",
    },
    .{
        .trigger = "case",
        .label = "case/when",
        .body = "case ${1:expression}\\nwhen ${2:value}\\n  $0\\nend",
        .detail = "Case statement",
    },
    .{
        .trigger = "begin",
        .label = "begin/rescue",
        .body = "begin\\n  $1\\nrescue ${2:StandardError} => ${3:e}\\n  $0\\nend",
        .detail = "Exception handling",
    },
    .{
        .trigger = "each",
        .label = "each block",
        .body = "${1:collection}.each do |${2:item}|\\n  $0\\nend",
        .detail = "Each iterator",
    },
    .{
        .trigger = "map",
        .label = "map block",
        .body = "${1:collection}.map do |${2:item}|\\n  $0\\nend",
        .detail = "Map iterator",
    },
    .{
        .trigger = "select",
        .label = "select block",
        .body = "${1:collection}.select do |${2:item}|\\n  $0\\nend",
        .detail = "Select/filter iterator",
    },
    .{
        .trigger = "frozen",
        .label = "frozen_string_literal",
        .body = "# frozen_string_literal: true\\n",
        .detail = "Frozen string literal pragma",
    },
    .{
        .trigger = "pp",
        .label = "pp debug",
        .body = "pp ${1:value}",
        .detail = "Pretty print debug",
    },
    .{
        .trigger = "req",
        .label = "require",
        .body = "require '${1:library}'",
        .detail = "Require statement",
    },
    .{
        .trigger = "reqr",
        .label = "require_relative",
        .body = "require_relative '${1:path}'",
        .detail = "Require relative",
    },
};

pub const RAILS_SNIPPETS = [_]Snippet{
    .{
        .trigger = "val_pres",
        .label = "validates presence",
        .body = "validates :${1:field}, presence: true",
        .detail = "Presence validation",
    },
    .{
        .trigger = "val_uniq",
        .label = "validates uniqueness",
        .body = "validates :${1:field}, uniqueness: true",
        .detail = "Uniqueness validation",
    },
    .{
        .trigger = "val_len",
        .label = "validates length",
        .body = "validates :${1:field}, length: { ${2:maximum}: ${3:255} }",
        .detail = "Length validation",
    },
    .{
        .trigger = "val_fmt",
        .label = "validates format",
        .body = "validates :${1:field}, format: { with: ${2:/\\A.+\\z/} }",
        .detail = "Format validation",
    },
    .{
        .trigger = "val_num",
        .label = "validates numericality",
        .body = "validates :${1:field}, numericality: { ${2:greater_than}: ${3:0} }",
        .detail = "Numericality validation",
    },
    .{
        .trigger = "before_act",
        .label = "before_action",
        .body = "before_action :${1:method}",
        .detail = "Before action callback",
    },
    .{
        .trigger = "after_act",
        .label = "after_action",
        .body = "after_action :${1:method}",
        .detail = "After action callback",
    },
    .{
        .trigger = "before_save",
        .label = "before_save",
        .body = "before_save :${1:method}",
        .detail = "Before save callback",
    },
    .{
        .trigger = "after_save",
        .label = "after_save",
        .body = "after_save :${1:method}",
        .detail = "After save callback",
    },
    .{
        .trigger = "after_create",
        .label = "after_create",
        .body = "after_create :${1:method}",
        .detail = "After create callback",
    },
    .{
        .trigger = "scope",
        .label = "scope",
        .body = "scope :${1:name}, -> { ${0:where(active: true)} }",
        .detail = "Named scope",
    },
    .{
        .trigger = "has_many",
        .label = "has_many",
        .body = "has_many :${1:associations}",
        .detail = "Has many association",
    },
    .{
        .trigger = "belongs_to",
        .label = "belongs_to",
        .body = "belongs_to :${1:association}",
        .detail = "Belongs to association",
    },
    .{
        .trigger = "has_one",
        .label = "has_one",
        .body = "has_one :${1:association}",
        .detail = "Has one association",
    },
    .{
        .trigger = "habtm",
        .label = "has_and_belongs_to_many",
        .body = "has_and_belongs_to_many :${1:associations}",
        .detail = "HABTM association",
    },
    .{
        .trigger = "render",
        .label = "render partial",
        .body = "render partial: '${1:partial}'",
        .detail = "Render partial",
    },
    .{
        .trigger = "redirect",
        .label = "redirect_to",
        .body = "redirect_to ${1:path}, notice: '${2:Success}'",
        .detail = "Redirect with notice",
    },
    .{
        .trigger = "respond",
        .label = "respond_to",
        .body = "respond_to do |format|\\n  format.html { $1 }\\n  format.json { $0 }\\nend",
        .detail = "Respond to format",
    },
    .{
        .trigger = "strong",
        .label = "strong params",
        .body = "params.require(:${1:model}).permit(:${2:field})",
        .detail = "Strong parameters",
    },
    .{
        .trigger = "migration",
        .label = "migration",
        .body = "add_column :${1:table}, :${2:column}, :${3:string}",
        .detail = "Add column migration",
    },
};

pub const RSPEC_SNIPPETS = [_]Snippet{
    .{
        .trigger = "desc",
        .label = "describe block",
        .body = "describe ${1:subject} do\\n  $0\\nend",
        .detail = "RSpec describe",
    },
    .{
        .trigger = "context",
        .label = "context block",
        .body = "context '${1:when condition}' do\\n  $0\\nend",
        .detail = "RSpec context",
    },
    .{
        .trigger = "it",
        .label = "it example",
        .body = "it '${1:does something}' do\\n  $0\\nend",
        .detail = "RSpec example",
    },
    .{
        .trigger = "expect",
        .label = "expect assertion",
        .body = "expect(${1:subject}).to ${2:eq(${3:value})}",
        .detail = "RSpec expectation",
    },
    .{
        .trigger = "let",
        .label = "let definition",
        .body = "let(:${1:name}) { ${0:value} }",
        .detail = "RSpec let",
    },
    .{
        .trigger = "subject",
        .label = "subject definition",
        .body = "subject { ${0:described_class.new} }",
        .detail = "RSpec subject",
    },
    .{
        .trigger = "before",
        .label = "before block",
        .body = "before do\\n  $0\\nend",
        .detail = "RSpec before hook",
    },
    .{
        .trigger = "shared",
        .label = "shared_examples",
        .body = "shared_examples '${1:name}' do\\n  $0\\nend",
        .detail = "RSpec shared examples",
    },
};

pub fn matchSnippets(prefix: []const u8, alloc: std.mem.Allocator) ![]const Snippet {
    var results = std.ArrayList(Snippet).empty;
    const all_lists = [_][]const Snippet{
        &RUBY_SNIPPETS,
        &RAILS_SNIPPETS,
        &RSPEC_SNIPPETS,
    };
    for (all_lists) |list| {
        for (list) |snippet| {
            if (prefix.len == 0 or std.mem.startsWith(u8, snippet.trigger, prefix) or
                std.mem.startsWith(u8, snippet.label, prefix))
            {
                try results.append(alloc, snippet);
            }
        }
    }
    return results.toOwnedSlice(alloc);
}

test "match snippets by prefix" {
    const alloc = std.testing.allocator;
    const matches = try matchSnippets("def", alloc);
    defer alloc.free(matches);
    try std.testing.expect(matches.len >= 2);
}

test "match all snippets with empty prefix" {
    const alloc = std.testing.allocator;
    const matches = try matchSnippets("", alloc);
    defer alloc.free(matches);
    const total = RUBY_SNIPPETS.len + RAILS_SNIPPETS.len + RSPEC_SNIPPETS.len;
    try std.testing.expectEqual(total, matches.len);
}

test "match validates snippets" {
    const alloc = std.testing.allocator;
    const matches = try matchSnippets("val_", alloc);
    defer alloc.free(matches);
    try std.testing.expect(matches.len >= 4);
}

test "match rspec snippets" {
    const alloc = std.testing.allocator;
    const matches = try matchSnippets("desc", alloc);
    defer alloc.free(matches);
    try std.testing.expect(matches.len >= 1);
}

test "no match for gibberish" {
    const alloc = std.testing.allocator;
    const matches = try matchSnippets("zzzznotasnippet", alloc);
    defer alloc.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "snippet struct has all fields" {
    const s = RUBY_SNIPPETS[0];
    try std.testing.expect(s.trigger.len > 0);
    try std.testing.expect(s.label.len > 0);
    try std.testing.expect(s.body.len > 0);
    try std.testing.expect(s.detail.len > 0);
}

test "rails snippets have triggers" {
    for (RAILS_SNIPPETS) |s| {
        try std.testing.expect(s.trigger.len > 0);
    }
}

test "rspec snippets have triggers" {
    for (RSPEC_SNIPPETS) |s| {
        try std.testing.expect(s.trigger.len > 0);
    }
}
