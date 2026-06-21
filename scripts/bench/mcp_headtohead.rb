#!/usr/bin/env ruby
# frozen_string_literal: true

# MCP head-to-head driver: refract (--mcp) vs rubydex (rubydex_mcp).
# Both speak newline-delimited JSON-RPC (MCP 2025-06-18) over stdio.
#
# Six tool pairs are exercised with identical, seeded inputs drawn from the
# corpus, then compared on latency (p50/p95), answer-rate (non-empty result),
# cross-agreement (do both locate the same declaration file:line), peak RSS and
# cold-ready time.
#
#   pair            refract              rubydex
#   search          workspace_symbols    search_declarations
#   declaration     class_summary        get_declaration
#   descendants     type_hierarchy       get_descendants
#   const_refs      find_references      find_constant_references
#   file_decls      get_file_overview    get_file_declarations
#   stats           workspace_health     codebase_stats
#
# Usage: mcp_headtohead.rb
# Env:   ROOT=/path/to/corpus  [SEED=42] [N=60]
#        REFRACT=/path/to/refract  RUBYDEX_MCP=/path/to/rubydex_mcp
#        SERVERS="refract rubydex"
# Output: one JSON document on stdout.

require "json"
require "digest"
require "open3"

ROOT     = File.expand_path(ENV.fetch("ROOT"))
SEED     = (ENV["SEED"] || "42").to_i
N        = (ENV["N"] || "60").to_i
SERVERS  = (ENV["SERVERS"] || "refract rubydex").split
REFRACT  = ENV["REFRACT"] || File.expand_path("#{__dir__}/../../zig-out/bin/refract")
RUBYDEX  = ENV["RUBYDEX_MCP"] || "rubydex_mcp"
READY_BUDGET_S = (ENV["READY_BUDGET_S"] || "120").to_i

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def percentile(arr, p)
  return nil if arr.empty?
  s = arr.sort
  s[((s.length - 1) * p).round]
end

def stats_for(arr)
  return { n: 0 } if arr.empty?
  { n: arr.length,
    p50_ms: percentile(arr, 0.50).round(3),
    p95_ms: percentile(arr, 0.95).round(3),
    max_ms: arr.max.round(3),
    mean_ms: (arr.sum / arr.length.to_f).round(3) }
end

# ---------- MCP client (newline JSON-RPC) -----------------------------------

class McpClient
  attr_reader :rss_peak_kb
  def initialize(name, cmd, root:)
    @name = name
    @cmd = cmd
    @root = root
    @id = 0
    @rss_peak_kb = 0
    @stop = false
  end

  def start
    @in, @out, @err, @wait = Open3.popen3(*@cmd, chdir: @root)
    @in.sync = true
    @errthr = Thread.new { @err.each_line { |_l| } rescue nil }
    @pid = @wait.pid
    @rssthr = Thread.new do
      until @stop
        begin
          if (m = File.read("/proc/#{@pid}/status")[/VmRSS:\s+(\d+)/, 1])
            kb = m.to_i
            @rss_peak_kb = kb if kb > @rss_peak_kb
          end
        rescue StandardError
        end
        sleep 0.1
      end
    end
  end

  def stop
    @stop = true
    @rssthr&.join(1)
    begin; Process.kill("TERM", @pid); rescue StandardError; end
    @in.close rescue nil
  end

  def rpc(method, params, timeout: 20)
    @id += 1
    id = @id
    @in.write(JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params) + "\n")
    deadline = mono + timeout
    while mono < deadline
      line = read_line(deadline - mono)
      return nil unless line
      next unless line.strip.start_with?("{")
      msg = JSON.parse(line) rescue next
      return msg if msg["id"] == id
    end
    nil
  end

  def notify(method, params = {})
    @in.write(JSON.generate(jsonrpc: "2.0", method: method, params: params) + "\n")
  end

  # tools/call → returns parsed content (JSON text payload) or raw text/nil.
  def call(tool, args, timeout: 20)
    msg = rpc("tools/call", { name: tool, arguments: args }, timeout: timeout)
    return nil unless msg && msg["result"]
    txt = (msg.dig("result", "content") || []).map { |c| c["text"] }.compact.join
    return txt if txt.empty?
    JSON.parse(txt) rescue txt
  end

  private

  def read_line(timeout)
    return nil if timeout <= 0
    if IO.select([@out], nil, nil, timeout)
      @out.gets
    end
  rescue StandardError
    nil
  end
end

# ---------- Corpus probe sampling (neutral to both servers) -----------------

def gather_files(root, max: 400)
  Dir.glob(File.join(root, "**/*.rb")).reject do |p|
    rel = p.sub(/\A#{Regexp.escape(root)}\/?/, "")
    rel =~ %r{(\A|/)(node_modules|log|\.git|tmp|vendor|spec|test)(/|\z)} ||
      File.size(p) > 100_000 || File.size(p) < 200
  end.sort_by { |p| Digest::SHA1.hexdigest("#{SEED}:#{p}") }.first(max)
end

def seeded(arr, n) = arr.uniq.sort_by { |x| Digest::SHA1.hexdigest("#{SEED}:#{x}") }.first(n)

files = gather_files(ROOT)
abort "no .rb files in #{ROOT}" if files.empty?

class_names = []
const_names = []
files.each do |p|
  File.foreach(p) do |line|
    if (m = line.match(/^\s*(?:class|module)\s+([A-Z][A-Za-z0-9_]*)/))
      class_names << m[1]
    elsif (m = line.match(/^\s*([A-Z][A-Z0-9_]{2,})\s*=/))
      const_names << m[1]
    end
  end
end
rel_files = files.map { |p| p.sub(/\A#{Regexp.escape(ROOT)}\/?/, "") }

# rubydex is FQN-strict: get_declaration / find_constant_references / get_descendants
# reject bare leaf names ("not_found", "Try search_declarations ... for the correct
# FQN"). refract accepts bare names. To compare the *lookup* fairly we feed both
# servers identical fully-qualified names that rubydex itself recognises — resolved
# via a rubydex search_declarations preflight (home-field input for rubydex). The
# bare-vs-FQN ergonomic gap is reported separately, not folded into latency.
def resolve_fqns(seed_names, want_const:)
  bin = ENV["RUBYDEX_MCP"] || "rubydex_mcp"
  c = McpClient.new("rubydex-preflight", [bin], root: ROOT)
  c.start
  c.rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {},
                        clientInfo: { name: "pf", version: "0" } }, timeout: 30)
  c.notify("notifications/initialized")
  # let the in-memory index settle (inline check; nonempty? defined later)
  20.times do
    r = c.call("search_declarations", { "query" => seed_names.first.to_s[0, 4] }, timeout: 6)
    break if r.is_a?(Hash) && !(r["results"] || []).empty?
    sleep 0.2
  end
  out = []
  seed_names.each do |nm|
    res = c.call("search_declarations", { "query" => nm }, timeout: 6)
    rows = res.is_a?(Hash) ? (res["results"] || []) : []
    rows.each do |r|
      fqn = r["name"].to_s
      kind = r["kind"].to_s
      next if fqn.empty?
      if want_const
        next unless kind == "Constant"
      else
        next unless %w[Class Module].include?(kind)
        next if fqn.include?("#") || fqn.include?("@")
      end
      out << fqn.split(/[#(]/).first
      break
    end
    break if out.length >= N
  end
  c.stop
  out.uniq
end

# nonempty? is defined below; forward-declare use is fine in Ruby (called at runtime).
fqn_classes = resolve_fqns(seeded(class_names, N * 2), want_const: false)
fqn_consts  = resolve_fqns(seeded(const_names,  N * 2), want_const: true)

probes = {
  search:      seeded(class_names, N).map { |q| q[0, [q.length, 4].min] }.uniq,
  declaration: fqn_classes.first(N),
  descendants: fqn_classes.first(N),
  const_refs:  fqn_consts.first(N),
  file_decls:  seeded(rel_files, N),
}

# probe_kind => { refract: [tool, ->(x){args}], rubydex: [...] }
MAP = {
  search:      { refract: ["workspace_symbols", ->(x) { { "query" => x } }],
                 rubydex: ["search_declarations", ->(x) { { "query" => x } }] },
  declaration: { refract: ["class_summary", ->(x) { { "class_name" => x } }],
                 rubydex: ["get_declaration", ->(x) { { "name" => x } }] },
  descendants: { refract: ["type_hierarchy", ->(x) { { "class_name" => x } }],
                 rubydex: ["get_descendants", ->(x) { { "name" => x } }] },
  # constant references use each tool's native key convention for the SAME
  # constant: refract find_references matches by bare name (broad); rubydex
  # find_constant_references is FQN-exact. Feeding FQN to refract or bare to
  # rubydex is a category error, not a capability gap — so split the input.
  const_refs:  { refract: ["find_references", ->(x) { { "name" => x.split("::").last } }],
                 rubydex: ["find_constant_references", ->(x) { { "name" => x } }] },
  file_decls:  { refract: ["get_file_overview", ->(x) { { "file" => x } }],
                 rubydex: ["get_file_declarations", ->(x) { { "file_path" => x } }] },
}.freeze

def nonempty?(res)
  case res
  when nil then false
  when String then !res.strip.empty? && res.strip != "[]" && res.strip != "{}"
  when Array then !res.empty?
  when Hash
    return false if res.empty?
    # treat explicit error / not_found / empty-results payloads as no-answer
    return false if res["error"] || res["status"] == "not_found"
    if res.key?("results") then !(res["results"] || []).empty?
    elsif res.key?("locations") then !(res["locations"] || []).empty?
    elsif res.key?("references") then !(res["references"] || []).empty?
    else true
    end
  else true
  end
end

# Pull a comparable (file, line) declaration anchor out of either server's
# payload, for cross-agreement. Best-effort across both schemas.
def anchor(res)
  return nil unless res.is_a?(Hash)
  loc = res["location"] || res["declaration"] ||
        res.dig("definitions", 0) ||          # rubydex get_declaration
        res.dig("results", 0, "locations", 0) || # rubydex search row
        res.dig("results", 0) ||
        res.dig("locations", 0) ||
        res.dig("definition", 0) || res["definition"] ||
        res
  return nil unless loc.is_a?(Hash)
  file = loc["file"] || loc["path"] || loc["file_path"]
  line = loc["line"] || loc.dig("range", "start", "line") || loc["lineno"]
  return nil unless file
  [File.basename(file.to_s), line]
end

# ---------- Per-server run --------------------------------------------------

def server_cmd(name)
  case name
  when "refract" then [REFRACT, "--mcp"]
  when "rubydex" then [RUBYDEX]
  else abort "unknown server #{name}"
  end
end

def run_server(name)
  client = McpClient.new(name, server_cmd(name), root: ROOT)
  t0 = mono
  client.start
  init = client.rpc("initialize",
                    { protocolVersion: "2025-06-18", capabilities: {},
                      clientInfo: { name: "h2h", version: "0" } }, timeout: 30)
  client.notify("notifications/initialized")
  init_ms = ((mono - t0) * 1000).round(1)

  # Cold-ready: poll the search tool until it answers non-empty.
  tool, argf = MAP[:search][name.to_sym]
  ready_t0 = mono
  ready_ms = nil
  deadline = ready_t0 + READY_BUDGET_S
  probe_q = PROBES[:search].first || "A"
  while mono < deadline
    r = client.call(tool, argf.call(probe_q), timeout: 8)
    if nonempty?(r)
      ready_ms = ((mono - ready_t0) * 1000).round(1)
      break
    end
    sleep 0.3
  end
  ready_ms ||= ((mono - ready_t0) * 1000).round(1)

  per_pair = {}
  anchors = {}
  MAP.each do |kind, m|
    tool, argf = m[name.to_sym]
    lats = []
    answered = 0
    kind_anchors = {}
    (PROBES[kind] || []).each do |x|
      t = mono
      r = client.call(tool, argf.call(x), timeout: 15)
      lats << ((mono - t) * 1000)
      if nonempty?(r)
        answered += 1
        a = anchor(r)
        kind_anchors[x] = a if a
      end
    end
    n = (PROBES[kind] || []).length
    per_pair[kind] = stats_for(lats).merge(
      tool: tool, probes: n,
      answered: answered,
      answer_rate: n.zero? ? 0.0 : (answered.to_f / n).round(3)
    )
    anchors[kind] = kind_anchors
  end

  # stats pair (no probe input)
  stool = name == "refract" ? "workspace_health" : "codebase_stats"
  st = mono
  sres = client.call(stool, {}, timeout: 15)
  per_pair[:stats] = { tool: stool, latency_ms: ((mono - st) * 1000).round(3),
                       answered: nonempty?(sres) ? 1 : 0 }

  rss = (client.rss_peak_kb / 1024.0).round(1)
  client.stop
  { init_ms: init_ms, ready_ms: ready_ms, peak_rss_mb: rss,
    pairs: per_pair, anchors: anchors }
end

PROBES = probes

results = {}
SERVERS.each { |s| results[s] = run_server(s) }

# ---------- Cross-agreement (refract vs rubydex on same input) --------------

agreement = {}
if results["refract"] && results["rubydex"]
  MAP.each_key do |kind|
    ra = results["refract"][:anchors][kind] || {}
    da = results["rubydex"][:anchors][kind] || {}
    common = ra.keys & da.keys
    agree = common.count { |k| ra[k] && da[k] && ra[k][0] == da[k][0] }
    agreement[kind] = { compared: common.length, file_match: agree,
                        rate: common.empty? ? nil : (agree.to_f / common.length).round(3) }
  end
end

out = {
  corpus: ROOT, seed: SEED, n: N, servers: SERVERS,
  servers_result: results,
  agreement: agreement,
}
puts JSON.pretty_generate(out)
