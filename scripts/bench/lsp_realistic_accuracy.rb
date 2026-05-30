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
            structural_precision: struct_returned[n].zero? ? nil : (struct_valid[n].to_f / struct_returned[n]).round(3) }]
    end,
    references: server_names.to_h do |n|
      [n, { probes: ref_p[n].size,
            precision: ref_p[n].empty? ? nil : (ref_p[n].sum / ref_p[n].size).round(3),
            recall: ref_r[n].empty? ? nil : (ref_r[n].sum / ref_r[n].size).round(3) }]
    end,
    rename_consistency: server_names.to_h { |n| [n, { n: rename_total[n], consistent: rename_consistent[n] }] },
    structural_misses: struct_misses,
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
    next if tgt.nil?
    resolved[name] += 1
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
    own_refs = refs_set((ask.call(name, c, :references, uri, pr[:line], pr[:char], timeout: 6) || {})["result"])
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
    rename_total[name] += 1
    rename_consistent[name] += 1 if edit_locs.uniq.sort == own_refs
  end
end

# ---- refract diagnostic false-positive audit ------------------------------

if DIAG_AUDIT && clients.key?("refract") && !over_deadline.call
  by_code = Hash.new(0); refract_only = Hash.new(0); total = 0
  rivals = clients.keys - ["refract"]
  files.first(15).each do |path|
    info = opened[path]
    # benign edit (re-send identical text) to re-trigger diagnostics
    clients.each { |name, c| c.did_change(info[:uris][name], info[:text]) unless dropped.include?(name) || c.dead? rescue nil }
    diags = {}
    clients.each do |name, c|
      next if dropped.include?(name) || c.dead?
      uri = info[:uris][name]
      d = c.collect_push_diagnostics(uri, settle_ms: 800, hard_timeout: 6) rescue []
      diags[name] = Array(d).map { |x| [x.dig("range", "start", "line"), x["code"]] }
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
  }
end

clients.each_value(&:stop)

# ---- emit -----------------------------------------------------------------

do_emit.call(partial: over_deadline.call || def_attempted < def_probes.size)
