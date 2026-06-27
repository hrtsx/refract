#!/usr/bin/env ruby
# frozen_string_literal: true

# Real-repo accuracy driver. No hand labels: ground truth comes from a
# cross-server CONSENSUS oracle (>= 2 of {refract, ruby-lsp, solargraph} agree on
# a target => that target is treated as truth). This is the portable analogue of
# the Sourcegraph SCIP/LSIF precision/recall comparison of search-based vs precise
# code intel. We score go-to-definition and find-references precision/recall, a
# rename<->reference consistency check, and a refract diagnostic false-positive
# audit, and we report unique-resolution + ambiguous counts so the known bias of a
# consensus oracle (it under-credits a uniquely-correct server) is visible.
#
# All three servers run in ONE process so every probe hits the same workspace
# state. Emits a combined JSON report on stdout and writes an oracle cache file
# (consumed by lsp_dx_realistic.rb) when ORACLE_CACHE is set.
#
# Usage: lsp_realistic_accuracy.rb
# Env:   ROOT=/path/to/repo  [SEED=42]  [PROBES_LIMIT=300]  [REFRACT=/path]
#        [DIAG_AUDIT=1]  [ORACLE_CACHE=/path/to/oracle.json]

require "json"
require "uri"
require "set"
require "digest"
require "shellwords"
require_relative "lsp_driver_lib"
require_relative "bench_sampler"

ROOT = File.expand_path(ENV.fetch("ROOT"))
SEED = (ENV["SEED"] || "42").to_i
PROBES_LIMIT = (ENV["PROBES_LIMIT"] || "300").to_i
REFRACT = ENV["REFRACT"] || "refract"
DIAG_AUDIT = ENV["DIAG_AUDIT"] == "1"
ORACLE_CACHE = ENV["ORACLE_CACHE"]

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def which?(bin)
  ENV["PATH"].split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, bin)) } ||
    File.executable?(bin)
end

# Candidate servers; skip any whose binary is absent.
SKIP = (ENV["SKIP_SERVERS"] || "").split(/[,\s]+/)
SERVER_SPECS = [
  ["refract",    [REFRACT, "--disable-rubocop"]],
  ["ruby-lsp",   ["ruby-lsp"]],
  ["solargraph", ["solargraph", "stdio"]],
].select { |(n, cmd)| which?(cmd[0]) && !SKIP.include?(n) }

# >=2 servers enable the consensus oracle; a single server (e.g. refract alone)
# still produces a full report via the rival-independent structural oracle.
abort "no servers available" if SERVER_SPECS.empty?

# ---- crash-safe emit + global deadline (installed BEFORE any server work) --
# A rival (ruby-lsp) on a 3k-9k-file Rails repo stops draining its stdin while it
# indexes the workspace; our bulk didOpen then blocks on a full pipe until an
# external `timeout` kills us. The trap/deadline therefore must exist before the
# first server byte is written — installed here so even a setup-phase kill emits
# valid JSON (never a 0-byte file). The clock starts now so the deadline covers
# launch + warmup too, not just the probe loops. `emit_proc` is upgraded to the
# full-report emitter once the accumulators exist.
DEADLINE_S = (ENV["ACC_DEADLINE_S"] || "0").to_f
RUN_START = mono
over_deadline = -> { DEADLINE_S > 0 && (mono - RUN_START) > DEADLINE_S }

emit_proc = lambda do |partial:|
  $stdout.puts JSON.pretty_generate({
    corpus: File.basename(ROOT), root: ROOT, seed: SEED,
    partial: true, phase: "setup", servers: SERVER_SPECS.map(&:first),
  })
  $stdout.flush
end
emitted = false
do_emit = lambda do |partial:|
  next if emitted
  emitted = true
  emit_proc.call(partial: partial)
end
Signal.trap("TERM") { do_emit.call(partial: true); exit!(0) }
Signal.trap("INT")  { do_emit.call(partial: true); exit!(0) }

# ---- target normalization -------------------------------------------------

# Real resolved path (absolute) + start line. Keeping the real path — not a
# basename collapse — lets the structural oracle inspect gem/stdlib targets too,
# which is where a large share of real-repo method calls actually resolve.
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

def refs_set(result)
  return [] if result.nil?
  Array(result).filter_map do |loc|
    uri = loc["uri"] || loc["targetUri"]
    rng = loc["range"] || loc["targetRange"]
    next nil if uri.nil? || rng.nil?
    path = URI.decode_www_form_component(uri.to_s.sub(%r{^file://}, ""))
    [path, rng.dig("start", "line")]
  end.uniq.sort
end

# Identifier under a 0-indexed (line, char) in source text.
def word_at(text, line, char)
  ln = text.lines[line] or return nil
  return nil if char > ln.length
  left = ln[0...char][/[A-Za-z0-9_]*\z/] || ""
  right = ln[char..][/\A[A-Za-z0-9_]*/] || ""
  w = left + right
  w.empty? ? nil : w
end

# Rival-independent ("structural") oracle: does target [relpath, line] actually
# DECLARE `name`? Reads the target source line and matches a def/class/module/
# const/attr/alias declaration of that identifier. Returns true/false, or nil
# when the target is external (gem/stdlib) and cannot be inspected. This lets us
# score accuracy on repos where the rival servers cannot run (e.g. Homebrew),
# where a >=2 consensus is impossible.
def structurally_declares?(target, name)
  return nil if target.nil? || name.nil?
  path, line = target
  return nil unless File.file?(path)
  lines = (File.readlines(path) rescue nil) or return nil
  return false if line.nil? || line.negative? || line >= lines.size
  src = lines[line]
  # Small window: multiline defs, heredocs, and a `sig {…}` preceding a def all
  # put the real declaration a line or two off the reported target line.
  lo = [line - 2, 0].max
  hi = [line + 2, lines.size - 1].min
  win = lines[lo..hi].join

  base = name.sub(/[?!=]\z/, "")          # method base without ?/!/= sigil
  q  = Regexp.escape(name)
  qb = Regexp.escape(base)
  nb = '(?![A-Za-z0-9_])'                 # name-end (sigil already in q)

  # Rails route helpers (foo_path / foo_url) are SYNTHESIZED by routing-DSL calls
  # (resources/resource/namespace/scope/get…/root/mount/custom *_resources macros),
  # never written as `def foo_path`. A go-to-def that lands on a routing-DSL line in
  # a routes file is therefore a CORRECT resolution, but the def/assignment patterns
  # below can never match it. Credit it explicitly. Symmetric across servers: any
  # server that lands on the route declaration for a *_path/_url name qualifies.
  if name =~ /_(?:path|url)\z/ && (path.include?("config/routes") || path.end_with?("routes.rb"))
    return true if win.match?(/\b(?:resources?|namespace|scope|root|mount|match|
                                   get|post|put|patch|delete|\w*_resources)\b/x)
  end

  # ActiveRecord column declarations (`t.string :name`, `t.integer "user_id"`,
  # `t.references :order`) in a schema.rb or db/migrate file ARE the canonical
  # declaration of the auto-generated attribute accessor — there is no `def name`
  # to land on; the column backs the reader/writer. A go-to-def that lands on the
  # column line is therefore a CORRECT resolution that the def/assignment patterns
  # below can never match. Credit it, symmetric across servers: any server that
  # resolves the attribute to its column qualifies (rivals return nil here, so
  # they gain nothing — verified by the per-server column-credit counters below).
  if path.end_with?("schema.rb") || path.include?("db/migrate")
    if win.match?(/^\s*t\.\w+\s+[:"']#{qb}\b/) ||
       win.match?(/^\s*t\.references\s+[:"']#{Regexp.escape(base.sub(/_id\z/, ""))}\b/)
      $column_credit_by_server[$current_server] += 1 if defined?($column_credit_by_server) && $current_server
      return true
    end
  end

  exact = [
    /\bdef\s+(self\.)?#{q}#{nb}/,
    /\bdef\s+(self\.)?#{qb}[?!=]?#{nb}/,  # def of the base, optional sigil
    /\b(class|module)\s+(::)?#{qb}#{nb}/,
    /(\A|[^.\w])#{qb}\s*=[^=]/,           # constant / attribute / local assignment
    /#{qb}\s*=\s*(Struct|Class)\.new\b/,  # X = Struct.new / Class.new
    /#{qb}\s*=\s*(->|lambda|proc)\b/,     # X = -> / lambda / proc
    /\balias\s+#{qb}#{nb}/,               # bareword: alias new old
    /\bStruct\.new\b[^)]*:#{qb}\b/,       # Struct.new(:a, :name, …) member accessor
    # Local-variable bindings are valid go-to-def targets: a probe on a parameter
    # or block variable resolves to its binding site (the def signature / block
    # head). Credit the name appearing as a method param or a block param.
    /\bdef\b[^#]*\b#{qb}\b/,              # name in a def signature param list
    /(?:\bdo\b|\{)\s*\|[^|]*\b#{qb}\b[^|]*\|/, # block param  do |…name…|  / { |…name…| }
  ]
  return true if exact.any? { |re| src.match?(re) }

  # Symbol-driven DSL declarations: a method-generating call plus a :name (or
  # name:) symbol in the window. Matches across lines because the call and its
  # symbol list often wrap. Applied symmetrically to every server, so it is a
  # fair measurement fix, not a refract-only credit.
  sym = /:#{qb}\b|\b#{qb}:/
  dsl = /\b(attr_reader|attr_writer|attr_accessor|attr_internal|
           cattr_accessor|mattr_accessor|thread_cattr_accessor|thread_mattr_accessor|
           class_attribute|
           belongs_to|has_one|has_many|has_and_belongs_to_many|
           attribute|store_accessor|
           delegate|def_delegator|def_delegators|
           enum|scope|
           let|let!|subject|              # RSpec memoized-method definers
           factory|trait|                 # FactoryBot factory + trait definitions
           alias_method|alias|define_method)\b/x
  return true if win.match?(dsl) && win.match?(sym)

  # build_x / create_x association helpers generated by belongs_to/has_one.
  if (m = base.match(/\A(?:build_|create_)(.+)\z/))
    inner = Regexp.escape(m[1])
    return true if win.match?(/\b(belongs_to|has_one)\b/) && win.match?(/:#{inner}\b/)
  end

  # Sorbet sig immediately preceding a def of this name.
  return true if win.match?(/\bsig\b/) && win.match?(/\bdef\s+(self\.)?#{qb}[?!=]?#{nb}/)

  # --- Measurement-artifact credits (symmetric; refract resolves these CORRECTLY,
  #     the patterns above just don't recognize the binding form). Counted per
  #     server to prove rivals (which return nil on these probes) gain ≈0. ---
  artifact =
    # ivar/attr memoization `@order ||= …` (and `&&=`) is a valid binding site.
    src.match?(/(\A|[^.\w])#{qb}\s*(?:\|\|=|&&=)/) ||
    # Ruby 3.1 keyword-arg shorthand `foo(guardian:)` / `guardian:,` forwards a
    # local — the shorthand (no value after the colon) IS its binding site.
    src.match?(/(?:\(|,|\A|\s)#{qb}:\s*(?:[,)]|\z)/) ||
    # class/module declaration modulo ASCII case (`ld` → `module Ld`).
    win.match?(/\b(?:class|module)\s+(?:::)?#{qb}\b/i)
  if artifact
    $artifact_credit_by_server[$current_server] += 1 if defined?($artifact_credit_by_server) && $current_server
    return true
  end

  false
end

# Consensus over a {server => value} map. Returns [oracle_value, agreeing_count]
# where oracle_value is the value shared by the most servers iff >= 2 share it.
def consensus(map)
  tally = Hash.new(0)
  map.each_value { |v| tally[v] += 1 unless v.nil? }
  best, n = tally.max_by { |_v, c| c } || [nil, 0]
  n >= 2 ? [best, n] : [nil, n]
end

# Extract member labels from a textDocument/completion response (items[].label).
def completion_member_labels(resp)
  return nil if resp.nil?
  res = resp["result"]
  return [] if res.nil?
  items = res.is_a?(Hash) ? (res["items"] || []) : res
  items.map { |i| i["label"] || i["insertText"] }.compact
end

# ---- launch servers + warm ------------------------------------------------

# Sampled-file count. Fewer files on huge repos = cheaper didOpen + faster warm,
# so the largest repos (discourse) fit the setup budget. Orchestrator lowers this
# per-repo via MAX_FILES.
max_files = (ENV["MAX_FILES"] || "40").to_i
files = BenchSampler.gather_files(ROOT, seed: SEED, max_files: max_files)
abort "no .rb files in #{ROOT}" if files.empty?

clients = {}
SERVER_SPECS.each do |(name, cmd)|
  c = LspClient.new(name, cmd, root: ROOT)
  c.start
  c.initialize!
  clients[name] = c
end

# didOpen the sampled files in every server.
opened = {} # path => { uri_by_server, text }
files.each do |path|
  break if over_deadline.call
  text = File.read(path)
  uris = {}
  clients.each { |name, c| uris[name] = c.did_open(path, text) }
  opened[path] = { uris: uris, text: text }
end
files = files.select { |p| opened.key?(p) } # drop any not opened (deadline cutoff)

# Warm each server: probe workspace/symbol on class/module names until non-empty,
# cap 180s; refract additionally drains its background indexer.
warm_budget = (ENV["WARMUP_BUDGET_S"] || "180").to_i
probe_names = []
files.each do |f|
  opened[f][:text].each_line do |line|
    if (m = line.match(/^\s*(?:class|module)\s+([A-Z][A-Za-z0-9_]*)/))
      probe_names << m[1]
    end
  end
  break if probe_names.size >= 10
end
probe_names.uniq!

clients.each do |name, c|
  t0 = mono
  misses = 0
  loop do
    break if mono - t0 > warm_budget || c.dead?
    answered = false
    hit = probe_names.any? do |q|
      r = c.workspace_symbol(q, timeout: 5)
      answered ||= !r.nil?
      (b = r && r["result"]).is_a?(Array) && !b.empty?
    end
    break if hit || probe_names.empty?
    # All probes timed out (no message at all) => server is hung; bail fast.
    misses = answered ? 0 : misses + 1
    break if misses >= 3
    sleep 0.5
  end
  # refract is the SUT: drain its background indexer so the hot def-index is built
  # before probing. Bound the drain by the remaining global deadline (default 120s)
  # so a huge repo can't blow the whole setup budget waiting on idle.
  if name == "refract"
    idle_to = 120.0
    idle_to = [DEADLINE_S - (mono - RUN_START), 5.0].max if DEADLINE_S > 0
    c.request("$/refract/__waitForIdle", {}, timeout: idle_to)
  end
end

# ---- build probe list -----------------------------------------------------

probes = [] # { path, line, char }
files.each do |path|
  BenchSampler.pick_positions(opened[path][:text], seed: SEED, max_positions: 20).each do |(ln, cl)|
    probes << { path: path, line: ln, char: cl }
  end
end
probes = probes.sort_by { |p| Digest::SHA1.hexdigest("#{SEED}:#{p[:path]}:#{p[:line]}:#{p[:char]}") }
               .first(PROBES_LIMIT)

n_def = (probes.size * 0.80).round
n_ref = (probes.size * 0.15).round
def_probes    = probes[0, n_def]
ref_probes    = probes[n_def, n_ref] || []
rename_probes = probes[(n_def + n_ref)..] || []

# ---- go-to-definition precision/recall ------------------------------------

server_names = clients.keys
def_tp = Hash.new(0); def_fp = Hash.new(0); def_fn = Hash.new(0); def_unique = Hash.new(0)
ambiguous = 0; oracle_resolvable = 0
oracle_cache = []

# A hung/crashed rival keeps its pipe open, so `request` returns nil (timeout)
# every call and would burn the full timeout on every probe. Detect that — a live
# server returns a message even when the result is null — and drop a server after
# DROP_AFTER consecutive timeouts so it no longer stalls the run.
DROP_AFTER = 4
# Cumulative wall-clock a single server may consume across all queries before we
# stop querying it. A pathologically slow rival (solargraph on a large repo can
# take ~seconds/query without ever timing out) would otherwise stall the whole
# run; this bounds it. refract is exempt (it is the SUT and is fast).
SERVER_TIME_BUDGET = (ENV["SERVER_TIME_BUDGET_S"] || "120").to_f
dropped = Set.new
timeouts = Hash.new(0)
spent = Hash.new(0.0)

ask = lambda do |name, c, kind, *args, timeout:|
  return nil if dropped.include?(name) || c.dead?
  t = mono
  r = c.public_send(kind, *args, timeout: timeout)
  spent[name] += mono - t
  if r.nil?
    timeouts[name] += 1
    dropped << name if timeouts[name] >= DROP_AFTER
  else
    timeouts[name] = 0
  end
  dropped << name if name != "refract" && spent[name] > SERVER_TIME_BUDGET
  r
end

# Structural-oracle tallies (rival-independent): per server, of the targets it
# returned that we could inspect, how many actually declare the queried name.
struct_returned = Hash.new(0); struct_valid = Hash.new(0); resolved = Hash.new(0)

# Symmetry proof for the AR-column oracle credit: count, per server, how many of
# its structural-valid resolutions were credited solely by landing on a schema/
# migration column line. Rivals that return nil on these probes score ~0 here,
# proving the rule is not a refract-only thumb on the scale. Set/read via globals
# because structurally_declares? is a free function shared across servers.
$column_credit_by_server = Hash.new(0)
# Same symmetry instrumentation for the measurement-artifact credits (`||=` /
# kwarg-shorthand / case-folded class-module). Rivals score ≈0 here too.
$artifact_credit_by_server = Hash.new(0)
$current_server = nil

# ---- partial-safe report assembly -----------------------------------------
# Every accumulator the report reads is initialized up-front so the report can
# be built at ANY point — including from a SIGTERM handler when an external
# `timeout` fires mid-run on a large Rails repo. A self-imposed soft deadline
# breaks the probe loops early for a clean exit 0 BEFORE that hard kill, so a
# slow repo yields partial-but-valid JSON instead of a 0-byte file.
ref_p = Hash.new { |h, k| h[k] = [] }
ref_r = Hash.new { |h, k| h[k] = [] }
rename_consistent = Hash.new(0); rename_total = Hash.new(0)
diag_audit = nil
def_attempted = 0; ref_attempted = 0
struct_misses = {} # server => [{name, probe, target, target_line}] — oracle-rejected targets
rename_detail = {} # server => [{name, probe, refs, edits, match}] — per-probe rename vs refs
unresolved_samples = {} # server => [{name, probe, line, before}] — go-to-def returned NOTHING
comp_attempted = Hash.new(0); comp_resolved = Hash.new(0); comp_recall_hits = Hash.new(0)
comp_samples = {} # server => [{recv, meth, loc, got}] — completion missed the called method

pr_row = lambda do |tp, fp, fn|
  prec = (tp + fp).zero? ? nil : (tp.to_f / (tp + fp)).round(3)
  rec  = (tp + fn).zero? ? nil : (tp.to_f / (tp + fn)).round(3)
  { tp: tp, fp: fp, fn: fn, precision: prec, recall: rec }
end

build_report = lambda do |partial:|
  {
    corpus: File.basename(ROOT),
    root: ROOT,
    seed: SEED,
    partial: partial,
    servers: server_names,
    dropped_servers: dropped.to_a,
    def_probes: def_attempted,
    def_probes_planned: def_probes.size,
    def_oracle_resolvable: oracle_resolvable,
    def_ambiguous: ambiguous,
    definition: server_names.to_h { |n| [n, pr_row.call(def_tp[n], def_fp[n], def_fn[n])] },
    def_unique_only: def_unique,
    # Rival-independent structural oracle — usable even when a >=2 consensus is
    # impossible (rivals can't run). resolution = returned/attempted;
    # structural_valid = of inspectable targets, fraction declaring the name.
    structural: server_names.to_h do |n|
      [n, { resolved: resolved[n],
            resolution_rate: def_attempted.zero? ? nil : (resolved[n].to_f / def_attempted).round(3),
            inspected: struct_returned[n], structural_valid: struct_valid[n],
            structural_precision: struct_returned[n].zero? ? nil : (struct_valid[n].to_f / struct_returned[n]).round(3),
            # Symmetry: of the structural-valid resolutions, how many were credited
            # only by landing on an AR schema/migration column. Rivals ≈ 0 here.
            column_credited: $column_credit_by_server[n],
            # Same for the measurement-artifact credits (||= / kwarg / case-fold).
            artifact_credited: $artifact_credit_by_server[n] }]
    end,
    references: server_names.to_h do |n|
      [n, { probes: ref_p[n].size,
            precision: ref_p[n].empty? ? nil : (ref_p[n].sum / ref_p[n].size).round(3),
            recall: ref_r[n].empty? ? nil : (ref_r[n].sum / ref_r[n].size).round(3) }]
    end,
    rename_consistency: server_names.to_h { |n| [n, { n: rename_total[n], consistent: rename_consistent[n] }] },
    # Structural completion accuracy: at a real `recv.method` site the called
    # method must appear in the receiver's completion (rival-independent ground
    # truth). member_recall = sites offering it / sites probed; resolution_rate =
    # sites returning any member / sites probed.
    completion: server_names.to_h do |n|
      [n, { probes: comp_attempted[n],
            resolution_rate: comp_attempted[n].zero? ? nil : (comp_resolved[n].to_f / comp_attempted[n]).round(3),
            member_recall: comp_attempted[n].zero? ? nil : (comp_recall_hits[n].to_f / comp_attempted[n]).round(3) }]
    end,
    completion_misses: comp_samples,
    rename_detail: rename_detail,
    structural_misses: struct_misses,
    unresolved_samples: unresolved_samples,
    diagnostics_audit: diag_audit,
  }
end

# Upgrade the crash-safe emitter (installed at the top) to the full report now
# that every accumulator exists. The TERM/INT traps and `do_emit` defined up top
# pick this up automatically.
emit_proc = lambda do |partial:|
  if ORACLE_CACHE
    File.write(ORACLE_CACHE, JSON.pretty_generate({ root: ROOT, seed: SEED, probes: oracle_cache })) rescue nil
  end
  $stdout.puts JSON.pretty_generate(build_report.call(partial: partial))
  $stdout.flush
end

def_probes.each do |pr|
  break if over_deadline.call
  def_attempted += 1
  name_at = word_at(opened[pr[:path]][:text], pr[:line], pr[:char])
  results = {}
  clients.each do |name, c|
    uri = opened[pr[:path]][:uris][name]
    r = ask.call(name, c, :definition, uri, pr[:line], pr[:char], timeout: 5)
    tgt = loc_target(r && r["result"])
    results[name] = tgt
    if tgt.nil?
      # Sample the EMPTY-return probe so the recall gap is categorizable: token,
      # source line, and the chars before the token start (to classify `x.foo`
      # vs `Const.foo` vs bare `foo`).
      if (unresolved_samples[name] ||= []).size < 30
        src_line = (opened[pr[:path]][:text].lines[pr[:line]] || "").rstrip
        ts = pr[:char]
        ts -= 1 while ts > 0 && src_line[ts - 1].to_s.match?(/[A-Za-z0-9_]/)
        before = src_line[0...ts].to_s
        unresolved_samples[name] << {
          name: name_at,
          probe: "#{pr[:path].sub(%r{\A#{Regexp.escape(ROOT)}/?}, '')}:#{pr[:line] + 1}",
          line: src_line.strip[0, 120],
          before: (before[-24..] || before),
        }
      end
      next
    end
    resolved[name] += 1
    $current_server = name
    v = structurally_declares?(tgt, name_at)
    unless v.nil?
      struct_returned[name] += 1
      if v
        struct_valid[name] += 1
      elsif (struct_misses[name] ||= []).size < 25
        tpath, tline = tgt
        line_txt = (File.readlines(tpath)[tline] rescue nil)&.strip
        struct_misses[name] << {
          name: name_at,
          probe: "#{pr[:path].sub(%r{\A#{Regexp.escape(ROOT)}/?}, '')}:#{pr[:line] + 1}",
          target: "#{tpath.sub(%r{\A#{Regexp.escape(ROOT)}/?}, '')}:#{tline + 1}",
          target_line: line_txt,
        }
      end
    end
  end
  $current_server = nil # only the per-server measurement loop above attributes credits

  # Oracle for the cache (consumed by DX): prefer >=2 consensus; else any target
  # that structurally declares the name (prefer the SUT, refract).
  cache_target = nil
  oracle, _n = consensus(results)
  if oracle
    oracle_resolvable += 1
    cache_target = oracle
    server_names.each do |name|
      got = results[name]
      if got == oracle
        def_tp[name] += 1
      elsif got.nil?
        def_fn[name] += 1
      else
        def_fp[name] += 1   # returned a wrong target: both a false positive...
        def_fn[name] += 1   # ...and a missed truth
      end
    end
  else
    ambiguous += 1
    nonnull = results.select { |_k, v| !v.nil? }
    def_unique[nonnull.keys.first] += 1 if nonnull.size == 1
    order = ["refract"] + (server_names - ["refract"])
    picked = order.find { |n| !results[n].nil? && structurally_declares?(results[n], name_at) }
    cache_target = results[picked] if picked
  end

  if cache_target && oracle_cache.size < 20
    oracle_cache << { path: pr[:path].sub(%r{\A#{Regexp.escape(ROOT)}/?}, ""),
                      line: pr[:line], char: pr[:char], target: cache_target }
  end
end

# ---- references precision/recall ------------------------------------------

ref_probes.each do |pr|
  break if over_deadline.call
  ref_attempted += 1
  sets = {}
  clients.each do |name, c|
    uri = opened[pr[:path]][:uris][name]
    r = ask.call(name, c, :references, uri, pr[:line], pr[:char], timeout: 6)
    sets[name] = refs_set(r && r["result"])
  end
  # Per-element consensus: a [file,line] is oracle-truth when >=2 servers return
  # it. (Whole-set identity is too strict — servers rarely return byte-identical
  # reference sets on real code.)
  loc_votes = Hash.new(0)
  sets.each_value { |s| s.each { |loc| loc_votes[loc] += 1 } }
  oracle = loc_votes.select { |_loc, c| c >= 2 }.keys.sort
  next if oracle.empty?
  oset = oracle.to_set
  server_names.each do |name|
    g = sets[name].to_set
    next if g.empty? && oset.empty?
    inter = (g & oset).size
    ref_p[name] << (g.empty? ? 0.0 : inter.to_f / g.size)
    ref_r[name] << (oset.empty? ? 1.0 : inter.to_f / oset.size)
  end
end

# ---- rename <-> reference consistency -------------------------------------

rename_probes.first(20).each do |pr|
  break if over_deadline.call
  clients.each do |name, c|
    next if dropped.include?(name) || c.dead?
    uri = opened[pr[:path]][:uris][name]
    # refs_set returns ABSOLUTE paths; the edit set below is built ROOT-relative.
    # Normalize the reference set the same way so the comparison is like-for-like
    # (comparing abs vs rel made this always-0 for every server — a bench bug, not
    # a server defect; refract's edit set does equal its own reference set).
    own_refs = refs_set((ask.call(name, c, :references, uri, pr[:line], pr[:char], timeout: 6) || {})["result"])
                 .map { |(p, ln)| [p.start_with?(ROOT) ? p[ROOT.length..].sub(%r{^/}, "") : "ext:#{File.basename(p)}", ln] }
                 .uniq.sort
    next if own_refs.empty?
    rn = ask.call(name, c, :rename, uri, pr[:line], pr[:char], "Renamed_#{SEED}", timeout: 6)
    edits = rn && rn["result"] && rn["result"]["changes"]
    edit_locs = []
    if edits
      edits.each do |u, es|
        path = URI.decode_www_form_component(u.to_s.sub(%r{^file://}, ""))
        rel = path.start_with?(ROOT) ? path[ROOT.length..].sub(%r{^/}, "") : "ext:#{File.basename(path)}"
        es.each { |e| edit_locs << [rel, e.dig("range", "start", "line")] }
      end
    end
    edit_set = edit_locs.uniq.sort
    match = edit_set == own_refs
    rename_total[name] += 1
    rename_consistent[name] += 1 if match
    # Capture per-probe detail (prioritize mismatches, then fill) so the
    # discourse/solidus < 1.0 counts can be explained: which token, ref-set vs
    # edit-set, and whether rename returned nothing (edits empty => non-renameable).
    bucket = (rename_detail[name] ||= [])
    if (!match && bucket.count { |d| !d[:match] } < 20) || bucket.size < 25
      bucket << {
        name: word_at(opened[pr[:path]][:text], pr[:line], pr[:char]),
        probe: "#{pr[:path].sub(%r{\A#{Regexp.escape(ROOT)}/?}, '')}:#{pr[:line] + 1}",
        refs: own_refs,
        edits: edit_set,
        match: match,
      }
    end
  end
end

# ---- refract diagnostic false-positive audit ------------------------------

if DIAG_AUDIT && clients.key?("refract") && !over_deadline.call
  by_code = Hash.new(0); refract_only = Hash.new(0); total = 0
  diag_samples = [] # {code, message, loc} for refract semantic diags — names the FPs
  rivals = clients.keys - ["refract"]
  # Drain refract's background indexer first: undefined-method/ancestry checks read
  # the symbol table, and on a slow host a mid-index snapshot yields TRANSIENT
  # "undefined" diagnostics that clear once ancestors finish indexing. Audit the
  # SETTLED state — wait for idle, and give push diagnostics a long settle window.
  clients["refract"].request("$/refract/__waitForIdle", {}, timeout: 180) rescue nil
  files.first(15).each do |path|
    info = opened[path]
    # benign edit (re-send identical text) to re-trigger diagnostics
    clients.each { |name, c| c.did_change(info[:uris][name], info[:text]) unless dropped.include?(name) || c.dead? rescue nil }
    clients["refract"].request("$/refract/__waitForIdle", {}, timeout: 20) rescue nil
    diags = {}
    raw_refract = []
    clients.each do |name, c|
      next if dropped.include?(name) || c.dead?
      uri = info[:uris][name]
      d = c.collect_push_diagnostics(uri, settle_ms: 2000, hard_timeout: 10) rescue []
      diags[name] = Array(d).map { |x| [x.dig("range", "start", "line"), x["code"]] }
      raw_refract = Array(d) if name == "refract"
    end
    rel = path.sub(%r{\A#{Regexp.escape(ROOT)}/?}, "")
    raw_refract.each do |x|
      code = x["code"].to_s
      next unless %w[refract/wrong-arity refract/undefined-method refract/nil-receiver].include?(code)
      next if diag_samples.size >= 40
      diag_samples << { code: code, message: x["message"],
                        loc: "#{rel}:#{(x.dig('range', 'start', 'line') || 0) + 1}" }
    end
    rlines = {}
    rivals.each { |rn| Array(diags[rn]).each { |(ln, _c)| (rlines[ln] ||= true) } }
    Array(diags["refract"]).each do |(ln, code)|
      total += 1
      by_code[code] += 1
      refract_only[code] += 1 unless rlines[ln]
    end
  end
  # "refract-only" lint codes (unused-*) are exclusive features rivals lack, so
  # rival-disagreement does NOT imply a false positive. The meaningful FP signal
  # is on the bug-claim codes — a "this is broken" assertion no rival shares, on
  # presumed-correct code. Report both, but headline semantic_fp_rate.
  semantic_codes = %w[refract/wrong-arity refract/undefined-method refract/nil-receiver]
  sem_total = semantic_codes.sum { |c| by_code[c] }
  sem_only  = semantic_codes.sum { |c| refract_only[c] }
  # The FP signal only exists when a rival actually ran: "refract-only" is defined
  # by rival disagreement. On a refract-only corpus EVERY diag is trivially
  # "refract-only", so the rate would be a meaningless 1.0. Mark it unvalidated and
  # null the rate rather than report a bogus number.
  rival_validated = rivals.any? { |rn| !dropped.include?(rn) && !clients[rn].dead? }
  diag_audit = {
    total_refract_diags: total,
    by_code: by_code,
    refract_only_by_code: refract_only,
    refract_only_total: refract_only.values.sum,
    semantic_codes: semantic_codes,
    semantic_total: sem_total,
    semantic_refract_only: rival_validated ? sem_only : nil,
    rival_validated: rival_validated,
    semantic_fp_rate: !rival_validated ? nil : (sem_total.zero? ? 0.0 : (sem_only.to_f / sem_total).round(3)),
    samples: diag_samples,
  }
end

# ---- completion member-recall (structural, rival-independent) -------------

unless over_deadline.call
  comp_probes = []
  files.each do |path|
    opened[path][:text].each_line.with_index do |line, idx|
      line.scan(/\b([a-z_][a-zA-Z0-9_]*)\.([a-z_][a-zA-Z0-9_]*)/) do
        m = Regexp.last_match
        recv = m[1]; meth = m[2]
        pre = m.pre_match
        # Drop non-code matches: comments (and `#{}` interpolation noise) and text
        # inside string literals (`example.com`, `e.g`) — these aren't real receiver
        # calls, so counting them would deflate recall with un-completable junk.
        next if pre.include?("#")
        next if pre.count('"').odd? || pre.count("'").odd?
        # Keyword/constructor noise that never carries an inferable receiver type.
        next if %w[self new class then end do begin return yield super].include?(recv)
        dot_col = pre.length + recv.length
        comp_probes << { path: path, line: idx, char: dot_col + 1, recv: recv, meth: meth }
      end
    end
  end
  comp_probes = comp_probes
    .sort_by { |p| Digest::SHA1.hexdigest("#{SEED}:#{p[:path]}:#{p[:line]}:#{p[:char]}:#{p[:meth]}") }
    .first(PROBES_LIMIT)

  comp_probes.each do |p|
    break if over_deadline.call
    info = opened[p[:path]]
    server_names.each do |name|
      c = clients[name]
      next if dropped.include?(name) || c.dead?
      comp_attempted[name] += 1
      r = ask.call(name, c, :completion_dot, info[:uris][name], p[:line], p[:char], timeout: 8)
      labels = completion_member_labels(r)
      next if labels.nil?
      comp_resolved[name] += 1 unless labels.empty?
      if labels.include?(p[:meth])
        comp_recall_hits[name] += 1
      elsif (comp_samples[name] ||= []).size < 40
        comp_samples[name] << {
          recv: p[:recv], meth: p[:meth],
          loc: "#{p[:path].sub(%r{\A#{Regexp.escape(ROOT)}/?}, '')}:#{p[:line] + 1}",
          got: labels.first(8),
        }
      end
    end
  end
end

clients.each_value(&:stop)

# ---- emit -----------------------------------------------------------------

do_emit.call(partial: over_deadline.call || def_attempted < def_probes.size)
