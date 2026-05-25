#!/usr/bin/env ruby
# frozen_string_literal: true

# Real-repo DX driver. Replays a per-repo oracle cache (def probes + their
# consensus targets, produced by lsp_realistic_accuracy.rb) against ONE server to
# measure developer-experience on a large codebase: cold init, time-to-first-
# CORRECT-answer (distribution + full-warm), robustness against a malformed file
# injected into the real tree, and resource cost.
#
# Usage: lsp_dx_realistic.rb <name> <command...>
# Env:   ROOT=/path/to/repo  ORACLE_CACHE=/path/to/oracle.json  [WARMUP_BUDGET_S=180]

require "json"
require "uri"
require "shellwords"
require_relative "lsp_driver_lib"
require_relative "bench_sampler"

ROOT = File.expand_path(ENV.fetch("ROOT"))
ORACLE_CACHE = ENV.fetch("ORACLE_CACHE")
CAP = (ENV["WARMUP_BUDGET_S"] || "180").to_i
NAME = ARGV[0]
CMD = ARGV[1..]

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def loc_target(result)
  return nil if result.nil?
  loc = result.is_a?(Array) ? result.first : result
  return nil if loc.nil? || loc.empty?
  uri = loc["targetUri"] || loc["uri"]
  rng = loc["targetRange"] || loc["targetSelectionRange"] || loc["range"]
  return nil if uri.nil? || rng.nil?
  path = URI.decode_www_form_component(uri.to_s.sub(%r{^file://}, ""))
  [path, rng.dig("start", "line")]
end

cache = JSON.parse(File.read(ORACLE_CACHE))
probes = (cache["probes"] || []).map do |p|
  { path: File.join(ROOT, p["path"]), line: p["line"], char: p["char"], target: p["target"] }
end
abort "empty oracle cache #{ORACLE_CACHE}" if probes.empty?

client = LspClient.new(NAME, CMD, root: ROOT)
t0 = mono
client.start
client.initialize!
cold_init_ms = ((mono - t0) * 1000).round(1)

# didOpen every file a probe lives in.
uris = {}
probes.map { |p| p[:path] }.uniq.each do |path|
  next unless File.file?(path)
  uris[path] = client.did_open(path, File.read(path))
end

# Poll until each probe first returns its oracle target. Record per-probe
# first-correct latency; full-warm = when >=90% are correct.
first_correct = {}
warm_t0 = mono
full_warm_ms = nil
target_correct = (probes.size * 0.9).ceil
loop do
  break if mono - warm_t0 > CAP || client.dead?
  probes.each_with_index do |p, i|
    next if first_correct.key?(i)
    uri = uris[p[:path]]
    next if uri.nil?
    r = client.definition(uri, p[:line], p[:char], timeout: 6)
    if r && loc_target(r["result"]) == p[:target]
      first_correct[i] = ((mono - warm_t0) * 1000).round(1)
    end
  end
  if full_warm_ms.nil? && first_correct.size >= target_correct
    full_warm_ms = ((mono - warm_t0) * 1000).round(1)
  end
  break if first_correct.size >= probes.size
  sleep 0.1
end

idle_ms = nil
if NAME == "refract"
  it0 = mono
  client.request("$/refract/__waitForIdle", {}, timeout: 120)
  idle_ms = ((mono - it0) * 1000).round(1)
end

# Robustness: inject a malformed file INTO the real tree, confirm survival + that
# a known-good probe still resolves.
broken = File.join(ROOT, "__refract_dx_broken__.rb")
survived = false; still_serving = false
begin
  src = "class __DxBroken\n  def oops(\n    x = nil\n  end\n  # unterminated \"\n"
  buri = client.did_open(broken, src)
  sleep 0.5
  survived = !client.dead?
  if survived
    p = probes.find { |pp| first_correct.key?(probes.index(pp)) } || probes.first
    uri = uris[p[:path]]
    r = uri && client.definition(uri, p[:line], p[:char], timeout: 6)
    still_serving = !!(r && loc_target(r["result"]) == p[:target])
  end
ensure
  File.delete(broken) if File.exist?(broken)
end

client.stop

fc = first_correct.values
index_disk_kb = nil
if NAME == "refract"
  db = `cd #{ROOT.shellescape} && #{CMD[0].shellescape} --print-db-path 2>/dev/null`.strip
  if !db.empty?
    total = [db, "#{db}-wal", "#{db}-shm"].select { |f| File.exist?(f) }.sum { |f| File.size(f) }
    index_disk_kb = (total / 1024.0).round(1)
  end
end

clk_tck = (`getconf CLK_TCK 2>/dev/null`.to_i.nonzero? || 100)

puts JSON.pretty_generate({
  name: NAME,
  corpus: File.basename(ROOT),
  cold_init_ms: cold_init_ms,
  probes: probes.size,
  first_correct_count: fc.size,
  first_correct: BenchSampler.stats_for(fc),
  full_warm_ms: full_warm_ms,
  full_warm_capped: full_warm_ms.nil?,
  warmup_idle_ms: idle_ms,
  robustness: { survived_malformed: survived, still_serving_after: still_serving },
  peak_rss_mb: (client.rss_peak_kb / 1024.0).round(1),
  peak_fd: client.fd_peak,
  cpu_total_ms: ((client.cpu_jiffies_final.to_f / clk_tck) * 1000).round(1),
  index_disk_kb: index_disk_kb,
})
