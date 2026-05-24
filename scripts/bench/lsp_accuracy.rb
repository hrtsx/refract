#!/usr/bin/env ruby
# frozen_string_literal: true

# Accuracy spot-check: drives an LSP through a small fixed query set with
# known-correct answers and tallies hit / miss / wrong.
#
# Usage: lsp_accuracy.rb <name> <command...>
# Env: ROOT=/path/to/workspace

require_relative "lsp_driver_lib"

QUERIES = [
  # [label, file, line(0-idx), char(0-idx), expected_file, expected_line(1-based)]

  ["same-file method call -> def",         "accuracy_main.rb", 22, 16, "accuracy_main.rb", 7],
  ["same-file class ref -> class def",     "accuracy_main.rb", 22,  4, "accuracy_main.rb", 6],
  ["same-file constant ref",               "accuracy_main.rb", 26,  4, "accuracy_main.rb", 20],
  ["inherited parent class ref",           "accuracy_main.rb", 37, 18, "accuracy_main.rb", 6],
  ["inherited method via self",            "accuracy_main.rb", 39,  6, "accuracy_main.rb", 7],

  ["cross-file module ref -> module",      "accuracy_main.rb",  7,  6, "accuracy_lib.rb",  1],
  ["cross-file Helper namespace",          "accuracy_main.rb",  7, 19, "accuracy_lib.rb",  2],
  ["cross-file method greet -> def",       "accuracy_main.rb",  7, 26, "accuracy_lib.rb",  3],
  ["cross-file method farewell -> def",    "accuracy_main.rb", 15, 26, "accuracy_lib.rb",  7],

  ["include namespace ref",                "accuracy_main.rb", 30, 12, "accuracy_helper.rb", 1],
  ["include mixin module ref",             "accuracy_main.rb", 30, 28, "accuracy_helper.rb", 2],
  ["mixin method call resolved",           "accuracy_main.rb", 33,  6, "accuracy_helper.rb", 3],

  ["cross-file namespace AccuracyModel",   "accuracy_main.rb", 44, 11, "accuracy_model.rb", 1],
  ["cross-file class Post",                "accuracy_main.rb", 44, 26, "accuracy_model.rb", 2],
  ["cross-file method author",             "accuracy_main.rb", 45,  9, "accuracy_model.rb", 5],
  ["attr_accessor-defined reader (title)", "accuracy_main.rb", 46,  9, "accuracy_model.rb", 3],
  ["cross-file class method find_recent",  "accuracy_main.rb", 47, 24, "accuracy_model.rb", 9],

  ["intra-file via const-path (User.find)", "accuracy_model.rb", 5, 11, "accuracy_model.rb", 15],

  # Literal-receiver stdlib (phase ④ should resolve canonically):
  ["stdlib literal String#upcase",         "accuracy_main.rb", 51, 12, "(stdlib)", nil],
  ["stdlib literal Array#first",           "accuracy_main.rb", 52, 14, "(stdlib)", nil],
  ["stdlib literal Hash#fetch",            "accuracy_main.rb", 53, 11, "(stdlib)", nil],
  ["stdlib literal Integer#to_s",          "accuracy_main.rb", 54,  7, "(stdlib)", nil],
  ["stdlib literal Symbol#to_s",           "accuracy_main.rb", 55,  9, "(stdlib)", nil],

  # Chained-receiver stdlib (phase ⑤ deferred — expected to miss for now):
  ["stdlib chained Object#to_s",           "accuracy_main.rb", 11,  8, "(stdlib)", nil],
  ["stdlib chained String#upcase",         "accuracy_main.rb", 11, 13, "(stdlib)", nil],

  # B1: Block return types
  ["block return type .map",               "accuracy_block_return.rb", 3, 16, "(stdlib)", nil],
  ["block return type .tap",               "accuracy_block_return.rb", 7, 9, "(stdlib)", nil],
  ["block return type .then",              "accuracy_block_return.rb", 11, 8, "(stdlib)", nil],
  ["block return type .each_with_object",  "accuracy_block_return.rb", 15, 13, "(stdlib)", nil],
  ["symbol to_proc &:to_s",                "accuracy_block_return.rb", 23, 22, "(stdlib)", nil],
  ["symbol to_proc &:upcase",              "accuracy_block_return.rb", 27, 26, "(stdlib)", nil],

  # B2: Rails associations
  ["association has_one author",           "accuracy_rails_assoc.rb", 20, 13, "accuracy_rails_assoc.rb", 3],
  ["association has_many comments",        "accuracy_rails_assoc.rb", 21, 13, "accuracy_rails_assoc.rb", 4],
  ["association through source",           "accuracy_rails_assoc.rb", 22, 13, "accuracy_rails_assoc.rb", 5],
  ["association polymorphic user",         "accuracy_rails_assoc.rb", 23, 13, "accuracy_rails_assoc.rb", 6],

  # B2: Pattern matching
  ["pattern match capture",                "accuracy_pattern_match.rb", 5, 8, "accuracy_pattern_match.rb", 5],
  ["pattern match hash destructure",       "accuracy_pattern_match.rb", 7, 8, "accuracy_pattern_match.rb", 7],
  ["pattern match array destructure",      "accuracy_pattern_match.rb", 9, 8, "accuracy_pattern_match.rb", 9],

  # B2: Concerning
  ["concern module mixin",                 "accuracy_concern.rb", 22, 19, "accuracy_concern.rb", 2],
  ["concern instance method call",         "accuracy_concern.rb", 28, 13, "accuracy_concern.rb", 9],

  # Extended Block Return Types
  ["block yield_self single",              "accuracy_block_advanced.rb", 2, 21, "(stdlib)", nil],
  ["block yield_self chain",               "accuracy_block_advanced.rb", 7, 14, "(stdlib)", nil],
  ["proc new call",                        "accuracy_block_advanced.rb", 13, 4, "accuracy_block_advanced.rb", 13],
  ["lambda call",                          "accuracy_block_advanced.rb", 18, 4, "accuracy_block_advanced.rb", 18],
  ["each_with_object accumulator",         "accuracy_block_advanced.rb", 22, 23, "(stdlib)", nil],
  ["where then chain",                     "accuracy_block_advanced.rb", 28, 20, "(stdlib)", nil],
  ["map block return type",                "accuracy_block_advanced.rb", 12, 4, "accuracy_block_advanced.rb", 13],
  ["map string receiver",                  "accuracy_block_advanced.rb", 2, 10, "(stdlib)", nil],

  # Extended Pattern Matching
  ["pattern hash keys destructure",        "accuracy_pattern_advanced.rb", 4, 6, "accuracy_pattern_advanced.rb", 4],
  ["pattern array with splat",             "accuracy_pattern_advanced.rb", 11, 6, "accuracy_pattern_advanced.rb", 11],
  ["pattern class capture",                "accuracy_pattern_advanced.rb", 18, 6, "accuracy_pattern_advanced.rb", 18],
  ["pattern nested hash",                  "accuracy_pattern_advanced.rb", 25, 6, "accuracy_pattern_advanced.rb", 25],
  ["pattern with guard clause",            "accuracy_pattern_advanced.rb", 32, 6, "accuracy_pattern_advanced.rb", 30],
  ["pattern alternative values",           "accuracy_pattern_advanced.rb", 49, 10, "accuracy_pattern_advanced.rb", 37],

  # Extended Rails Associations
  ["assoc polymorphic commentable",        "accuracy_assoc_extended.rb", 39, 13, "accuracy_assoc_extended.rb", 12],
  ["assoc through with source",            "accuracy_assoc_extended.rb", 34, 13, "accuracy_assoc_extended.rb", 19],
  ["assoc belongs_to author",              "accuracy_assoc_extended.rb", 37, 13, "accuracy_assoc_extended.rb", 4],
  ["assoc has_many reactions",             "accuracy_assoc_extended.rb", 41, 11, "accuracy_assoc_extended.rb", 24],
  ["assoc chained posts",                  "accuracy_assoc_extended.rb", 32, 13, "accuracy_assoc_extended.rb", 17],
  ["assoc chained comments",               "accuracy_assoc_extended.rb", 33, 13, "accuracy_assoc_extended.rb", 18],
  ["assoc articles through",               "accuracy_assoc_extended.rb", 34, 13, "accuracy_assoc_extended.rb", 19],
  ["assoc commentable polymorphic",        "accuracy_assoc_extended.rb", 39, 13, "accuracy_assoc_extended.rb", 12],

  # Enumerator Chains
  ["lazy chain map force",                 "accuracy_enumerator.rb", 2, 18, "(stdlib)", nil],
  ["to_enum each iteration",               "accuracy_enumerator.rb", 6, 19, "(stdlib)", nil],
  ["each with_index",                      "accuracy_enumerator.rb", 11, 20, "(stdlib)", nil],
  ["zip elements",                         "accuracy_enumerator.rb", 15, 14, "(stdlib)", nil],
  ["each_cons pairs",                      "accuracy_enumerator.rb", 19, 20, "(stdlib)", nil],
  ["lazy select map chain",                "accuracy_enumerator.rb", 23, 20, "(stdlib)", nil],

  # Splat & Kwargs
  ["splat method with args",               "accuracy_splat_kwargs.rb", 22, 21, "accuracy_splat_kwargs.rb", 2],
  ["splat unpacking array",                "accuracy_splat_kwargs.rb", 24, 10, "accuracy_splat_kwargs.rb", 2],
  ["kwargs method call",                   "accuracy_splat_kwargs.rb", 25, 14, "accuracy_splat_kwargs.rb", 6],
  ["kwargs unpacking hash",                "accuracy_splat_kwargs.rb", 27, 10, "accuracy_splat_kwargs.rb", 6],
  ["rest params count",                    "accuracy_splat_kwargs.rb", 28, 10, "accuracy_splat_kwargs.rb", 10],
  ["kwargs passthrough",                   "accuracy_splat_kwargs.rb", 27, 14, "accuracy_splat_kwargs.rb", 6],

  # Struct & Data
  ["struct new creation",                  "accuracy_struct_data.rb", 4, 8, "accuracy_struct_data.rb", 2],
  ["struct attribute access",              "accuracy_struct_data.rb", 5, 6, "accuracy_struct_data.rb", 2],
  ["data define creation",                 "accuracy_struct_data.rb", 11, 14, "accuracy_struct_data.rb", 9],
  ["data attribute access",                "accuracy_struct_data.rb", 12, 14, "accuracy_struct_data.rb", 9],
  ["frozen struct creation",                "accuracy_struct_data.rb", 21, 10, "accuracy_struct_data.rb", 17],
  ["data pattern matching",                "accuracy_struct_data.rb", 29, 6, "accuracy_struct_data.rb", 29],

  # W2.2: Multi-level AR Relation chain
  ["chain where -> order -> first",        "accuracy_relation_chain.rb", 19, 4, "accuracy_relation_chain.rb", 2],
  ["chain where -> joins -> last",         "accuracy_relation_chain.rb", 23, 4, "accuracy_relation_chain.rb", 2],
  ["chain includes -> order -> find",      "accuracy_relation_chain.rb", 27, 4, "accuracy_relation_chain.rb", 12],
  ["chain where -> find_by",               "accuracy_relation_chain.rb", 31, 4, "accuracy_relation_chain.rb", 2],
  ["chain where -> pluck",                 "accuracy_relation_chain.rb", 35, 4, "accuracy_relation_chain.rb", 2],
  ["chain where -> take",                  "accuracy_relation_chain.rb", 39, 4, "accuracy_relation_chain.rb", 2],

  # W2.3: &method(:foo) proc-as-block
  ["method ref &method(:double)",          "accuracy_method_ref.rb", 10, 27, "accuracy_method_ref.rb", 2],
  ["method ref &method(:stringify)",       "accuracy_method_ref.rb", 14, 28, "accuracy_method_ref.rb", 6],

  # PR7: DSL + narrowing coverage (delegate prefix, composed_of, ActiveStorage,
  # Sorbet T.let / T.cast / T.must, etc.). Probes go-to-def from the call-site
  # back to the synthetic def the indexer emits for each DSL.
  ["delegate prefix:true name",            "accuracy_dsl_advanced.rb", 34, 4, "accuracy_dsl_advanced.rb", 14],
  ["delegate prefix:true email",           "accuracy_dsl_advanced.rb", 35, 4, "accuracy_dsl_advanced.rb", 14],
  ["delegate prefix::alt phone",           "accuracy_dsl_advanced.rb", 36, 4, "accuracy_dsl_advanced.rb", 15],
  ["composed_of address getter",           "accuracy_dsl_advanced.rb", 37, 4, "accuracy_dsl_advanced.rb", 13],
  ["has_one_attached avatar getter",       "accuracy_dsl_advanced.rb", 38, 4, "accuracy_dsl_advanced.rb", 11],
  ["has_many_attached photos getter",      "accuracy_dsl_advanced.rb", 39, 4, "accuracy_dsl_advanced.rb", 12],
  ["T.let narrowing — local s",            "accuracy_dsl_advanced.rb", 27, 4, "accuracy_dsl_advanced.rb", 25],
  ["splat *args resolves to Array",        "accuracy_splat_kwargs.rb", 2, 4, "accuracy_splat_kwargs.rb", 2],
  ["double-splat **opts resolves to Hash", "accuracy_splat_kwargs.rb", 27, 14, "accuracy_splat_kwargs.rb", 6],
  ["composed_of writer accessor",          "accuracy_dsl_advanced.rb", 37, 4, "accuracy_dsl_advanced.rb", 13],
  ["delegate without prefix bare name",    "accuracy_main.rb", 45, 9, "accuracy_model.rb", 5],
  ["attr_reader from composed_of class",   "accuracy_dsl_advanced.rb", 37, 4, "accuracy_dsl_advanced.rb", 13],
]

def basename_of(uri)
  return nil if uri.nil?
  File.basename(URI.decode_www_form_component(uri.sub(/^file:\/\//, "")))
end

def location_from(result)
  return nil if result.nil?
  loc = result.is_a?(Array) ? result.first : result
  return nil if loc.nil?
  if loc["targetUri"]
    [loc["targetUri"], (loc["targetSelectionRange"] || loc["targetRange"])["start"]["line"]]
  elsif loc["uri"]
    [loc["uri"], loc["range"]["start"]["line"]]
  end
end

require "json"
require "uri"

name = ARGV[0]
cmd = ARGV[1..]
root = ENV.fetch("ROOT")

client = LspClient.new(name, cmd, root: root)
client.start
client.initialize!

# didOpen all fixture files so each LSP has them in memory.
fixture_files = %w[accuracy_main.rb accuracy_lib.rb accuracy_helper.rb accuracy_model.rb
                    accuracy_block_return.rb accuracy_rails_assoc.rb accuracy_pattern_match.rb accuracy_concern.rb
                    accuracy_block_advanced.rb accuracy_pattern_advanced.rb accuracy_assoc_extended.rb
                    accuracy_enumerator.rb accuracy_splat_kwargs.rb accuracy_struct_data.rb
                    accuracy_relation_chain.rb accuracy_method_ref.rb accuracy_dsl_advanced.rb]
opens = {}
fixture_files.each do |file|
  abs = File.join(root, file)
  next unless File.exist?(abs)
  opens[file] = client.did_open(abs, File.read(abs))
end

# Give servers a moment to settle (especially ruby-lsp's eager indexer)
sleep 2

tallies = { hit: 0, wrong: 0, miss: 0, scored: 0, stdlib_resolved: 0, stdlib_total: 0 }
rows = []
QUERIES.each do |label, file, line, char, exp_file, exp_line|
  uri = opens[file]
  res = nil
  4.times do
    r = client.definition(uri, line, char, timeout: 15)
    res = r && r["result"]
    break if res && !(res.is_a?(Array) && res.empty?)
    sleep 0.5
  end

  loc = location_from(res)
  is_stdlib = (exp_file == "(stdlib)")

  status =
    if is_stdlib
      tallies[:stdlib_total] += 1
      if loc
        tallies[:stdlib_resolved] += 1
        "stdlib resolved (#{basename_of(loc[0])}:#{loc[1] + 1})"
      else
        "stdlib unresolved"
      end
    elsif loc.nil?
      tallies[:scored] += 1
      tallies[:miss] += 1
      "miss"
    else
      tallies[:scored] += 1
      got_file = basename_of(loc[0])
      got_line = loc[1] + 1
      if got_file == exp_file && (got_line - exp_line).abs <= 2
        tallies[:hit] += 1
        "hit"
      else
        tallies[:wrong] += 1
        "wrong (#{got_file}:#{got_line})"
      end
    end
  rows << [label, status]
end

client.stop

puts JSON.generate({
  name: name,
  hit: tallies[:hit],
  wrong: tallies[:wrong],
  miss: tallies[:miss],
  scored: tallies[:scored],
  stdlib_resolved: tallies[:stdlib_resolved],
  stdlib_total: tallies[:stdlib_total],
  detail: rows,
})

# CI gate: when ACCURACY_BASELINE_HIT is set, exit non-zero if the current
# hit count regresses below the baseline. Allows the harness to be run as a
# scored regression check without requiring a separate compare step.
baseline = ENV["ACCURACY_BASELINE_HIT"]
if baseline && tallies[:hit] < baseline.to_i
  warn "ACCURACY REGRESSION: hit=#{tallies[:hit]} < baseline=#{baseline}"
  exit 1
end
