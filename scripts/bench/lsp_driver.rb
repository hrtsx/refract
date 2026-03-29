#!/usr/bin/env ruby
# frozen_string_literal: true

# LSP perf driver. Times cold-start, measures p50/p95 of definition/hover/completion.
# Usage: lsp_driver.rb <server-name> <command...>
# Env: ROOT (workspace root), FIXTURE (file relative to ROOT to didOpen)

require "json"
require_relative "lsp_driver_lib"

root = ENV.fetch("ROOT")
fixture_rel = ENV.fetch("FIXTURE")
fixture_abs = File.join(root, fixture_rel)
text = File.read(fixture_abs)

name = ARGV[0]
cmd = ARGV[1..]
results = { name: name, root: root, fixture: fixture_rel }

client = LspClient.new(name, cmd, root: root)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
client.start
client.initialize!
t_init_done = Process.clock_gettime(Process::CLOCK_MONOTONIC)
results[:initialize_ms] = ((t_init_done - t0) * 1000).round(1)

uri = client.did_open(fixture_abs, text)

# Cold-to-first-def: poll definition on a same-file method call until non-empty.
t_query_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
first_def = nil
attempts = 0
loop do
  attempts += 1
  r = client.definition(uri, 15, 12, timeout: 60)
  body = r && r["result"]
  if body && !(body.is_a?(Array) && body.empty?)
    first_def = body
    break
  end
  break if attempts > 30
  sleep 0.5
end
t_first_def = Process.clock_gettime(Process::CLOCK_MONOTONIC)
results[:cold_to_first_def_ms] = ((t_first_def - t_query_start) * 1000).round(1)
results[:first_def_attempts] = attempts
results[:first_def_ok] = !first_def.nil?

def_times = []
hover_times = []
completion_times = []

10.times do
  a = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client.definition(uri, 15, 12, timeout: 10)
  def_times << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - a) * 1000)
end
10.times do
  a = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client.hover(uri, 15, 12, timeout: 10)
  hover_times << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - a) * 1000)
end
10.times do
  a = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client.completion(uri, 16, 24, timeout: 10)
  completion_times << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - a) * 1000)
end

pct = ->(arr, p) {
  sorted = arr.sort
  sorted[((sorted.length - 1) * p).round]
}

results[:def_p50_ms] = pct.call(def_times, 0.5).round(1)
results[:def_p95_ms] = pct.call(def_times, 0.95).round(1)
results[:hover_p50_ms] = pct.call(hover_times, 0.5).round(1)
results[:hover_p95_ms] = pct.call(hover_times, 0.95).round(1)
results[:completion_p50_ms] = pct.call(completion_times, 0.5).round(1)
results[:completion_p95_ms] = pct.call(completion_times, 0.95).round(1)
results[:peak_rss_mb] = (client.rss_peak_kb / 1024.0).round(1)

client.stop
puts JSON.pretty_generate(results)
