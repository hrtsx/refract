#!/usr/bin/env ruby
# frozen_string_literal: true

# Realistic LSP workload driver. Three modes:
#   WORKLOAD=session : editor-trace (hover 60% / def 15% / completion 10% /
#                      symbol 5% / refs 5% / docSym 3% / rename 2%) over a
#                      session that opens and edits multiple files.
#   WORKLOAD=typing  : sustained didChange at typing speed (8/s) for 30s
#                      while issuing hover/def/completion in parallel.
#   WORKLOAD=micro   : per-method micro at 50 random positions across 5 files.
#
# All modes pick files + positions from the corpus deterministically (seeded).
# Output: one JSON document on stdout describing per-method latency stats.
#
# Usage: lsp_realistic.rb <name> <command...>
# Env:   ROOT=/path/to/corpus  WORKLOAD=session|typing|micro  [SEED=42]

require "json"
require "digest"
require "shellwords"
require_relative "lsp_driver_lib"

ROOT = File.expand_path(ENV.fetch("ROOT"))
WORKLOAD = ENV.fetch("WORKLOAD")
SEED = (ENV["SEED"] || "42").to_i
NAME = ARGV[0]
CMD = ARGV[1..]

unless %w[session typing micro].include?(WORKLOAD)
  abort "WORKLOAD must be session|typing|micro (got #{WORKLOAD.inspect})"
end

# ---------- Corpus sampling -------------------------------------------------

def gather_files(root, max_files: 200)
  files = Dir.glob(File.join(root, "**/*.rb")).reject do |p|
    rel = p.sub(/\A#{Regexp.escape(root)}\/?/, "")
    rel =~ %r{(\A|/)(node_modules|log|\.git|tmp|vendor)(/|\z)} ||
      File.size(p) > 100_000 || # skip huge files
      File.size(p) < 200        # skip trivial files
  end
  files.sort_by { |p| Digest::SHA1.hexdigest("#{SEED}:#{p}") }.first(max_files)
end

# Pick positions where an identifier or method call is likely. Returns
# [line, char] pairs (0-indexed). Heuristic: any [a-z_][\w]*\.[a-z_][\w]* match.
def pick_positions(text, max_positions: 20)
  positions = []
  text.each_line.with_index do |line, idx|
    line.scan(/\b([a-z_][a-zA-Z0-9_]*)\.([a-z_][a-zA-Z0-9_]*)/) do
      m = Regexp.last_match
      # Position on the receiver part (line, start_of_match)
      pre = m.pre_match
      col = pre.length
      positions << [idx, col]
      # Also one position on the method name itself
      positions << [idx, col + m[1].length + 1]
    end
  end
  return positions if positions.size <= max_positions
  positions.sort_by { |lc| Digest::SHA1.hexdigest("#{SEED}:#{lc.join(",")}") }
           .first(max_positions)
end

def percentile(arr, p)
  return nil if arr.empty?
  s = arr.sort
  s[((s.length - 1) * p).round]
end

def stats_for(arr)
  return { n: 0 } if arr.empty?
  {
    n: arr.length,
    p50_ms: percentile(arr, 0.50).round(2),
    p95_ms: percentile(arr, 0.95).round(2),
    p99_ms: percentile(arr, 0.99).round(2),
    max_ms: arr.max.round(2),
    mean_ms: (arr.sum / arr.length.to_f).round(2),
  }
end

def time_block
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000)
end

# ---------- Common setup ----------------------------------------------------

files = gather_files(ROOT, max_files: WORKLOAD == "session" ? 12 : 5)
abort "no .rb files in #{ROOT}" if files.empty?

client = LspClient.new(NAME, CMD, root: ROOT)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
client.start
client.initialize!
init_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)

# didOpen all files we'll touch
opens = {}
files.each do |path|
  text = File.read(path)
  opens[path] = { uri: client.did_open(path, text), text: text }
end

# Wait for the workspace symbol index to be populated — proxies "indexer is
# warm enough to answer". Probe with workspace/symbol querying a class or
# module name extracted from the corpus; once any server returns a non-empty
# result, declare warm. Hard-cap to WARMUP_BUDGET_S (default 180s); each
# attempt has a short timeout to avoid blocking.
WARMUP_BUDGET_S = (ENV["WARMUP_BUDGET_S"] || "180").to_i

def extract_symbol_names(text, limit: 8)
  names = []
  text.each_line do |line|
    if (m = line.match(/^\s*(?:class|module)\s+([A-Z][A-Za-z0-9_]*)/))
      names << m[1]
      break if names.size >= limit
    end
  end
  names
end

probe_names = []
files.each do |f|
  probe_names.concat(extract_symbol_names(opens[f][:text], limit: 4))
  break if probe_names.size >= 8
end
probe_names.uniq!

warm_ms = nil
warm_ok = false
warm_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
deadline = warm_t0 + WARMUP_BUDGET_S
if probe_names.empty?
  # Fallback: if no class/module names found, use the legacy first-position
  # definition probe so the script still terminates.
  first_file = files.first
  first_positions = pick_positions(opens[first_file][:text], max_positions: 5)
  unless first_positions.empty?
    ln, cl = first_positions.first
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      r = client.definition(opens[first_file][:uri], ln, cl, timeout: 4)
      body = r && r["result"]
      if body && !(body.is_a?(Array) && body.empty?)
        warm_ok = true
        break
      end
      sleep 0.5
    end
  end
else
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    hit = probe_names.any? do |name|
      r = client.workspace_symbol(name, timeout: 4)
      body = r && r["result"]
      body.is_a?(Array) && !body.empty?
    end
    if hit
      warm_ok = true
      break
    end
    sleep 0.5
  end
end
warm_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - warm_t0) * 1000).round(1)

# Refract-specific: block until the bg indexer + hot-index rebuild are idle.
# Symbol probe above only proves the cold SQL path is queryable — hot index
# (def pre-render, params_sig cache, ...) may still be empty, which gives
# false-low cold p50s in micro mode. waitForIdle waits up to 10 s.
if NAME == "refract"
  idle_t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client.request("$/refract/__waitForIdle", {}, timeout: 30)
  idle_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - idle_t0) * 1000).round(1)
  warm_ms = (warm_ms || 0) + idle_ms
end

# ---------- Workload: session ----------------------------------------------

# Industry-derived editor-session mix (single session, ~200 ops total):
#   hover     60%   (mouse-over identifiers)
#   definition 15%  (Cmd-click / gd)
#   completion 10%  (typing dot/colon-colon)
#   symbol      5%  (Cmd-T / file picker)
#   references  5%  (find usages)
#   docSymbol   3%  (outline view)
#   rename      2%  (F2)
SESSION_MIX = {
  hover: 60, definition: 15, completion: 10,
  symbol: 5, references: 5, document_symbol: 3, rename: 2,
}.freeze
SESSION_OPS = 200

def run_session(client, opens, files)
  rng = Random.new(SEED)
  per_method = Hash.new { |h, k| h[k] = [] }
  diag_first = []
  diag_settle = []
  diag_count = 0

  # Build ops list weighted by SESSION_MIX.
  ops = []
  SESSION_MIX.each do |method, pct|
    (SESSION_OPS * pct / 100).times { ops << method }
  end
  ops.shuffle!(random: rng)

  # Inject a save+diagnostics every ~30 ops (typical user save cadence).
  saves_at = (0...ops.size).step(30).to_a[1..] || []

  ops.each_with_index do |op, idx|
    if client.respond_to?(:write_dead?) && client.write_dead?
      per_method[:server_died_at_op] = idx
      break
    end
    # Pick a random open file for this op
    file = files.sample(random: rng)
    positions = pick_positions(opens[file][:text], max_positions: 30)
    next if positions.empty?
    line, char = positions.sample(random: rng)
    uri = opens[file][:uri]

    ms = case op
         when :hover then time_block { client.hover(uri, line, char, timeout: 10) }
         when :definition then time_block { client.definition(uri, line, char, timeout: 10) }
         when :completion then time_block { client.completion(uri, line, char, timeout: 10) }
         when :references then time_block { client.references(uri, line, char, timeout: 15) }
         when :document_symbol then time_block { client.document_symbol(uri, timeout: 15) }
         when :symbol
           # Pick a query that's likely to match: a random identifier from text
           q = opens[file][:text].scan(/\bclass\s+([A-Z][\w]+)/).flatten.sample(random: rng) || "Application"
           time_block { client.workspace_symbol(q, timeout: 15) }
         when :rename
           time_block { client.rename(uri, line, char, "renamed_at_#{idx}", timeout: 15) }
         end
    per_method[op] << ms

    # Periodic save → wait for diagnostics
    if saves_at.include?(idx)
      ds = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client.did_save(uri, opens[file][:text])
      r = client.wait_for_diagnostics(uri: uri, started_at: ds, settle_ms: 600, hard_timeout: 12)
      diag_first << r[:first_ms] if r[:first_ms]
      diag_settle << r[:settle_ms] if r[:settle_ms]
      diag_count += r[:received_count]
    end
  end

  out = per_method.transform_values { |v| stats_for(v) }
  out[:diag_first_ms] = stats_for(diag_first)
  out[:diag_settle_ms] = stats_for(diag_settle)
  out[:diag_total_publishes] = diag_count
  out
end

# ---------- Workload: typing ------------------------------------------------

TYPING_DURATION_S = 30
TYPING_RATE_HZ = 8 # didChange per second
QUERY_RATE_HZ = 4  # interleaved hover/def/completion per second

def run_typing(client, opens, files)
  rng = Random.new(SEED)
  file = files.first
  uri = opens[file][:uri]
  base = opens[file][:text].dup
  positions = pick_positions(base, max_positions: 50)
  return { error: "no positions" } if positions.empty?

  per_method = Hash.new { |h, k| h[k] = [] }
  did_change_count = 0

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TYPING_DURATION_S
  next_change_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  next_query_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05

  while (now = Process.clock_gettime(Process::CLOCK_MONOTONIC)) < deadline
    if client.respond_to?(:write_dead?) && client.write_dead?
      per_method[:server_died] = true
      break
    end
    if now >= next_change_at
      # Mutate text by appending a no-op comment line — incremental change.
      mutated = base + "\n# typing edit #{did_change_count}"
      client.did_change(uri, mutated)
      did_change_count += 1
      next_change_at = now + 1.0 / TYPING_RATE_HZ
    elsif now >= next_query_at
      method = %i[hover definition completion].sample(random: rng)
      line, char = positions.sample(random: rng)
      ms = case method
           when :hover then time_block { client.hover(uri, line, char, timeout: 5) }
           when :definition then time_block { client.definition(uri, line, char, timeout: 5) }
           when :completion then time_block { client.completion(uri, line, char, timeout: 5) }
           end
      per_method[method] << ms
      next_query_at = now + 1.0 / QUERY_RATE_HZ
    else
      sleep [next_change_at, next_query_at].min - now
    end
  end

  out = per_method.transform_values { |v| stats_for(v) }
  out[:didchange_count] = did_change_count
  out[:duration_s] = TYPING_DURATION_S
  out
end

# ---------- Workload: micro -------------------------------------------------

def run_micro(client, opens, files)
  rng = Random.new(SEED)
  per_method = Hash.new { |h, k| h[k] = [] }
  positions = []
  files.each do |f|
    pick_positions(opens[f][:text], max_positions: 12).each do |lc|
      positions << [opens[f][:uri], lc[0], lc[1]]
    end
  end
  positions = positions.shuffle(random: rng).first(50)

  positions.each do |uri, line, char|
    per_method[:hover] << time_block { client.hover(uri, line, char, timeout: 10) }
  end
  positions.each do |uri, line, char|
    per_method[:definition] << time_block { client.definition(uri, line, char, timeout: 10) }
  end
  positions.each do |uri, line, char|
    per_method[:completion] << time_block { client.completion(uri, line, char, timeout: 10) }
  end

  per_method.transform_values { |v| stats_for(v) }
end

# ---------- Run -------------------------------------------------------------

result = {
  name: NAME,
  workload: WORKLOAD,
  root: ROOT,
  files_in_corpus: Dir.glob(File.join(ROOT, "**/*.rb")).length,
  files_opened: files.length,
  initialize_ms: init_ms,
  warmup_first_def_ms: warm_ms,
  warmup_ok: warm_ok,
  seed: SEED,
}

per_method = case WORKLOAD
             when "session" then run_session(client, opens, files)
             when "typing" then run_typing(client, opens, files)
             when "micro" then run_micro(client, opens, files)
             end

result[:per_method] = per_method
result[:peak_rss_mb] = (client.rss_peak_kb / 1024.0).round(1)
result[:peak_fd] = client.fd_peak
clk_tck = (`getconf CLK_TCK`.to_i.nonzero? || 100)
result[:cpu_total_ms] = ((client.cpu_jiffies_final.to_f / clk_tck) * 1000).round(1)

if NAME == "refract"
  begin
    db_path = `cd #{ROOT.shellescape} && #{CMD[0].shellescape} --print-db-path 2>/dev/null`.strip
    if !db_path.empty? && File.exist?(db_path)
      total = [db_path, "#{db_path}-wal", "#{db_path}-shm"].sum { |f| File.size(f) rescue 0 }
      result[:index_disk_kb] = (total / 1024.0).round(1)
      result[:index_path] = db_path
    end
  rescue StandardError
  end
end

client.stop
puts JSON.pretty_generate(result)
