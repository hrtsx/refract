#!/usr/bin/env ruby
# frozen_string_literal: true

# Multi-operation accuracy harness. Beyond go-to-definition (lsp_accuracy.rb),
# this scores hover, completion, references, rename, and diagnostics against a
# server-agnostic ground truth — the same correct answers are scored identically
# for every server.
#
# Usage: lsp_multiop.rb <name> <command...>
# Env: ROOT=/path/to/fixtures

require_relative "lsp_driver_lib"
require "json"
require "uri"

ROOT = ENV.fetch("ROOT")

def basename_of(uri)
  return nil if uri.nil?
  File.basename(URI.decode_www_form_component(uri.sub(%r{^file://}, "")))
end

# ---- Ground truth (positions are 0-indexed line/char; locs are 1-indexed lines) ----

# HOVER: hovering a symbol must return non-empty content containing the token.
HOVER = [
  ["hover method call greet",   "accuracy_main.rb",  7, 26, "greet"],
  ["hover chained to_s",        "accuracy_main.rb", 11,  8, "to_s"],
  ["hover attr title",          "accuracy_main.rb", 46,  9, "title"],
  ["hover class Post",          "accuracy_main.rb", 44, 26, "Post"],
  ["hover def greet (lib)",     "accuracy_lib.rb",   2, 13, "greet"],
  ["hover method author",       "accuracy_main.rb", 45,  9, "author"],
]

# COMPLETION: at a receiver dot (present at index time), member labels must appear.
# Dedicated trailing-dot fixtures so the receiver is indexed, not buffer-truncated.
COMPLETION = [
  ["complete local-var member (p.)",        "compl_local.rb",          9,  2, %w[author title]],
  ["complete constant class (Repo.)",       "compl_const.rb",          8, 16, %w[all find]],
  ["complete inherited member (d.)",        "compl_inherit.rb",        9,  2, %w[base_method own_method]],
  ["complete bare-const class object (w.)", "compl_bareconst.rb",      9,  2, %w[build lookup]],
  ["complete typed method param (acct.)",   "compl_param.rb",          9,  9, %w[balance freeze!]],
  ["complete nested cross-class inherited", "compl_nested_inherit.rb", 11, 2, %w[inherited_a inherited_b own_c]],
  ["complete multi-level chain (a.b.c.)",   "compl_chain.rb",          17, 12, %w[own_c]],
  ["complete array index element (a[0].)",  "compl_index.rb",           6, 10, %w[greet_name age_years]],
  ["complete collection first (a.first.)",  "compl_index.rb",           7, 13, %w[greet_name age_years]],
  ["complete bare-rescue var (e.)",         "compl_rescue.rb",          7,  4, %w[diag_detail]],
  ["complete attr_reader via ivar type",    "compl_attr.rb",           12, 12, %w[credit]],
]

# Dirty-buffer completion: the receiver's type only exists in an UNSAVED edit
# (didChange), never on disk. Proves the open_docs-first read path + debounced
# reindex feed completion. [file, edited-full-text, line, char, expected].
COMPLETION_DIRTY = [
  ["complete edited-in receiver (x.)", "compl_dirty.rb",
   "module CompDirty\n  class Thing\n    def alpha; end\n    def beta; end\n  end\nend\n\nx = CompDirty::Thing.new\nx.\n",
   8, 2, %w[alpha beta]],
]

# REFERENCES: query position -> expected reference locations (basename:1-based-line),
# includeDeclaration=true.
REFERENCES = [
  ["refs greet",   "accuracy_main.rb",  7, 26, [["accuracy_lib.rb", 3],  ["accuracy_main.rb", 8]]],
  ["refs Service", "accuracy_main.rb",  5,  8, [["accuracy_main.rb", 6],  ["accuracy_main.rb", 23], ["accuracy_main.rb", 38]]],
  ["refs CONST",   "accuracy_main.rb", 19,  2, [["accuracy_main.rb", 20], ["accuracy_main.rb", 27]]],
  ["refs call",    "accuracy_main.rb",  6,  8, [["accuracy_main.rb", 7],  ["accuracy_main.rb", 23], ["accuracy_main.rb", 40]]],
]

# RENAME: query position + new name -> expected edit locations (basename:1-based-line).
RENAME = [
  ["rename CONST", "accuracy_main.rb", 19,  2, "CONST2", [["accuracy_main.rb", 20], ["accuracy_main.rb", 27]]],
  ["rename greet", "accuracy_lib.rb",   2, 13, "greet2", [["accuracy_lib.rb", 3],  ["accuracy_main.rb", 8]]],
  ["rename call",  "accuracy_main.rb",  6,  8, "call2",  [["accuracy_main.rb", 7],  ["accuracy_main.rb", 23], ["accuracy_main.rb", 40]]],
]

# DIAGNOSTICS: real semantic bugs in diag_bugs.rb -> acceptable 1-based line(s).
# A bug counts as detected if the server emits any diagnostic on an acceptable line.
DIAG_FIXTURE = "diag_bugs.rb"
DIAG_BUGS = [
  ["duplicate-method",  [3, 7]],
  ["nil-receiver",      [17]],
  ["wrong-arity",       [18]],
  ["undefined-method",  [19]],
  ["unused-variable",   [20]],
  ["unused-parameter",  [24]],
]

# ---- helpers ----

def hover_text(result)
  return nil if result.nil?
  c = result["contents"]
  return nil if c.nil?
  case c
  when String then c
  when Array then c.map { |e| e.is_a?(Hash) ? (e["value"] || e["language"]) : e.to_s }.join(" ")
  when Hash then c["value"] || c["language"]
  end
end

def completion_labels(result)
  return [] if result.nil?
  items = result.is_a?(Hash) ? (result["items"] || []) : result
  items.map { |i| i["label"] || i["insertText"] }.compact
end

def ref_locs(result)
  return [] if result.nil?
  Array(result).map do |loc|
    uri = loc["uri"] || loc["targetUri"]
    rng = loc["range"] || loc["targetSelectionRange"] || loc["targetRange"]
    next nil unless uri && rng
    [basename_of(uri), rng["start"]["line"] + 1]
  end.compact
end

def rename_locs(result)
  return [] if result.nil?
  out = []
  if result["changes"]
    result["changes"].each do |uri, edits|
      edits.each { |e| out << [basename_of(uri), e["range"]["start"]["line"] + 1] }
    end
  end
  if result["documentChanges"]
    Array(result["documentChanges"]).each do |dc|
      uri = dc.dig("textDocument", "uri")
      Array(dc["edits"]).each { |e| out << [basename_of(uri), e["range"]["start"]["line"] + 1] }
    end
  end
  out
end

# precision/recall on a set of [file,line] tuples (dedup, line tolerance ±0)
def pr(got, expected)
  g = got.uniq
  e = expected.uniq
  tp = e.count { |x| g.include?(x) }
  prec = g.empty? ? (e.empty? ? 1.0 : 0.0) : (g.count { |x| e.include?(x) }.to_f / g.size)
  rec = e.empty? ? 1.0 : tp.to_f / e.size
  { tp: tp, got: g.size, exp: e.size, precision: prec.round(3), recall: rec.round(3) }
end

# ---- run ----

name = ARGV[0]
cmd = ARGV[1..]
client = LspClient.new(name, cmd, root: ROOT)
client.start
client.initialize!

fixtures = %w[accuracy_main.rb accuracy_lib.rb accuracy_helper.rb accuracy_model.rb
              accuracy_rails_assoc.rb diag_bugs.rb
              compl_local.rb compl_const.rb compl_inherit.rb
              compl_bareconst.rb compl_param.rb compl_nested_inherit.rb compl_dirty.rb
              compl_chain.rb compl_index.rb compl_rescue.rb compl_attr.rb]
opens = {}
fixtures.each do |f|
  abs = File.join(ROOT, f)
  opens[f] = client.did_open(abs, File.read(abs)) if File.exist?(abs)
end
sleep 5 # let eager indexers settle (cross-file decls take a beat)

report = { name: name, hover: [], completion: [], references: [], rename: [], diagnostics: [] }

# HOVER
HOVER.each do |label, file, line, char, token|
  uri = opens[file]
  txt = nil
  3.times do
    r = client.hover(uri, line, char, timeout: 15)
    txt = hover_text(r && r["result"])
    break if txt && !txt.empty?
    sleep 0.4
  end
  status = if txt.nil? || txt.empty?
             "empty"
           elsif txt.downcase.include?(token.downcase)
             "correct"
           else
             "resolved-no-token"
           end
  report[:hover] << { label: label, status: status }
end

# COMPLETION
COMPLETION.each do |label, file, line, char, expected|
  uri = opens[file]
  labels = []
  3.times do
    r = client.completion_dot(uri, line, char, timeout: 15)
    labels = completion_labels(r && r["result"])
    break if expected.all? { |m| labels.include?(m) }
    sleep 0.5
  end
  found = expected.select { |m| labels.include?(m) }
  report[:completion] << {
    label: label, found: found.size, expected: expected.size,
    recall: (expected.empty? ? 1.0 : (found.size.to_f / expected.size).round(3)),
    missing: expected - found,
  }
end

# COMPLETION (dirty buffer): apply the unsaved edit, then complete on it.
COMPLETION_DIRTY.each do |label, file, edited, line, char, expected|
  uri = opens[file]
  next unless uri
  client.did_change(uri, edited)
  labels = []
  4.times do
    r = client.completion_dot(uri, line, char, timeout: 15)
    labels = completion_labels(r && r["result"])
    break if expected.all? { |m| labels.include?(m) }
    sleep 0.5
  end
  found = expected.select { |m| labels.include?(m) }
  report[:completion] << {
    label: label, found: found.size, expected: expected.size,
    recall: (expected.empty? ? 1.0 : (found.size.to_f / expected.size).round(3)),
    missing: expected - found,
  }
end

# REFERENCES
REFERENCES.each do |label, file, line, char, expected|
  uri = opens[file]
  best = []
  4.times do
    r = client.references(uri, line, char, timeout: 15)
    got = ref_locs(r && r["result"])
    # keep the attempt that best matches expected (indexing converges across tries)
    best = got if pr(got, expected)[:tp] > pr(best, expected)[:tp] || (best.empty? && !got.empty?)
    break if pr(best, expected)[:recall] >= 1.0
    sleep 0.5
  end
  report[:references] << { label: label }.merge(pr(best, expected))
end

# RENAME
RENAME.each do |label, file, line, char, new_name, expected|
  uri = opens[file]
  r = client.rename(uri, line, char, new_name, timeout: 15)
  got = rename_locs(r && r["result"])
  report[:rename] << { label: label }.merge(pr(got, expected))
end

# DIAGNOSTICS (try push and pull; merge)
duri = opens[DIAG_FIXTURE]
diags = []
if duri
  # nudge a re-analysis
  client.did_change(duri, File.read(File.join(ROOT, DIAG_FIXTURE)))
  push = client.collect_push_diagnostics(duri, settle_ms: 1500, hard_timeout: 10)
  pull_resp = client.pull_diagnostics(duri, timeout: 10) rescue nil
  pull = []
  if pull_resp && pull_resp["result"]
    res = pull_resp["result"]
    pull = res["items"] || res["diagnostics"] || []
  end
  diags = (push + pull)
end
flagged_lines = diags.map { |d| d.dig("range", "start", "line") }.compact.map { |l| l + 1 }.uniq
DIAG_BUGS.each do |bug, lines|
  detected = (lines & flagged_lines).any?
  report[:diagnostics] << { bug: bug, detected: detected }
end
diag_summary = {
  bugs_detected: report[:diagnostics].count { |d| d[:detected] },
  bugs_total: DIAG_BUGS.size,
  total_diagnostics_emitted: diags.size,
}

client.stop

# ---- aggregate ----
hover_correct = report[:hover].count { |h| h[:status] == "correct" }
hover_nonempty = report[:hover].count { |h| h[:status] != "empty" }
comp_recall = report[:completion].sum { |c| c[:recall] } / [report[:completion].size, 1].max
refs_recall = report[:references].sum { |r| r[:recall] } / [report[:references].size, 1].max
refs_prec = report[:references].sum { |r| r[:precision] } / [report[:references].size, 1].max
rename_recall = report[:rename].sum { |r| r[:recall] } / [report[:rename].size, 1].max
rename_prec = report[:rename].sum { |r| r[:precision] } / [report[:rename].size, 1].max

summary = {
  name: name,
  hover: { correct: hover_correct, nonempty: hover_nonempty, total: HOVER.size },
  completion: { mean_recall: comp_recall.round(3), probes: report[:completion].size },
  references: { mean_recall: refs_recall.round(3), mean_precision: refs_prec.round(3), probes: REFERENCES.size },
  rename: { mean_recall: rename_recall.round(3), mean_precision: rename_prec.round(3), probes: RENAME.size },
  diagnostics: diag_summary,
}

puts JSON.pretty_generate({ summary: summary, detail: report })
