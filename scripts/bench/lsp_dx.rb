#!/usr/bin/env ruby
# frozen_string_literal: true

# DX timing probe: measures cold-init latency, time-to-first-correct-answer, and
# robustness on malformed input — empirically, per server.
#
# Usage: lsp_dx.rb <name> <command...>
# Env: ROOT=/path/to/fixtures

require_relative "lsp_driver_lib"
require "json"
require "uri"

ROOT = ENV.fetch("ROOT")

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def basename_of(uri)
  return nil if uri.nil?
  File.basename(URI.decode_www_form_component(uri.to_s.sub(%r{^file://}, "")))
end

def def_basename(result)
  return nil if result.nil?
  loc = result.is_a?(Array) ? result.first : result
  return nil if loc.nil?
  basename_of(loc["targetUri"] || loc["uri"])
end

name = ARGV[0]
cmd = ARGV[1..]

client = LspClient.new(name, cmd, root: ROOT)
t0 = mono
client.start
client.initialize!
cold_init_ms = ((mono - t0) * 1000).round(1)

main = File.join(ROOT, "accuracy_main.rb")
uri = client.did_open(main, File.read(main))

# Time-to-first-correct-answer: greet call (line 7 char 26) must resolve into
# accuracy_lib.rb. Poll until correct or cap.
cap = 60.0
start = mono
first_correct_ms = nil
while mono - start < cap
  r = client.definition(uri, 7, 26, timeout: 5)
  if r && def_basename(r["result"]) == "accuracy_lib.rb"
    first_correct_ms = ((mono - start) * 1000).round(1)
    break
  end
  sleep 0.25
end

# Robustness: open a syntactically broken document, then confirm the server is
# still alive and serving valid queries.
broken_path = File.join(ROOT, "__dx_broken.rb")
broken_src = "class Broken\n  def oops(\n    x = nil\n  end\n  # unterminated string \"\n"
broken_uri = client.did_open(broken_path, broken_src)
sleep 0.5
survived = !client.dead?
still_serving = false
if survived
  r = client.definition(uri, 7, 26, timeout: 5)
  still_serving = (r && def_basename(r["result"]) == "accuracy_lib.rb") || false
end

client.stop

puts JSON.generate({
  name: name,
  cold_init_ms: cold_init_ms,
  first_correct_ms: first_correct_ms,
  first_correct_capped: first_correct_ms.nil?,
  peak_rss_mb: (client.rss_peak_kb / 1024.0).round(1),
  robustness: { survived_malformed: survived, still_serving_after: still_serving },
})
