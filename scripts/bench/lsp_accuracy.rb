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
  # Service.new.call("world") on line 17 (idx 16): `c` of .call at col 16
  ["same-file method call -> def",      "accuracy_main.rb", 16, 16, "accuracy_main.rb", 5],
  # `S` of Service.new on line 17 (idx 16) at col 5 (inside "Service")
  ["same-file class ref -> class def",  "accuracy_main.rb", 16, 5,  "accuracy_main.rb", 4],
  # AccuracyLib::Helper.greet on line 6 (idx 5): `A` of AccuracyLib at col 6 -> col 7 inside
  ["cross-file module ref -> module",   "accuracy_main.rb", 5, 7,   "accuracy_lib.rb",  1],
  # .greet on line 6 (idx 5): `g` at col 25 -> col 26 inside
  ["cross-file method ref -> def",      "accuracy_main.rb", 5, 26,  "accuracy_lib.rb",  3],
  # s.to_s.upcase on line 10 (idx 9): `u` of upcase at col 14 -> 15 inside
  ["stdlib method (String#upcase)",     "accuracy_main.rb", 9, 15,  "(stdlib)",         nil],
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

# didOpen all referenced files so each LSP has them in memory
opens = {}
QUERIES.each do |_, file, *|
  next if opens[file]
  abs = File.join(root, file)
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
