#!/usr/bin/env ruby
# frozen_string_literal: true
#
# MCP token-efficiency harness. Quantifies how many tokens an AI agent spends
# answering common code-navigation questions via refract's MCP tools versus the
# "basic" alternative it would otherwise use (Read a file, grep the repo).
#
# For each task the MCP response payload is compared against a DELIBERATELY
# CONSERVATIVE baseline (the file the agent would Read, or the grep output it
# would scan) — no grep-to-locate cost is added to the file-read baselines, so
# the reported savings understate the real gap.
#
# Tokens are estimated at chars/4 (standard GPT-family approximation for ASCII
# source); raw bytes are reported alongside so the estimate is auditable.
#
# Usage: ROOT=<repo> REFRACT=<bin> [N=40] ruby mcp_token_efficiency.rb

require "json"
require "open3"
require "digest"

ROOT    = ENV.fetch("ROOT")
REFRACT = ENV.fetch("REFRACT")
SEED    = ENV["SEED"] || "42"
N       = (ENV["N"] || "40").to_i

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def est_tokens(bytes) = (bytes / 4.0).round

class Mcp
  def initialize(cmd, root)
    @cmd = cmd
    @root = root
    @id = 0
  end

  def start
    @in, @out, @err, @wait = Open3.popen3(*@cmd, chdir: @root)
    @in.sync = true
    @errthr = Thread.new { @err.each_line { |_l| } rescue nil }
    rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {},
                        clientInfo: { name: "tok", version: "0" } }, timeout: 40)
    notify("notifications/initialized")
  end

  def stop
    begin; Process.kill("TERM", @wait.pid); rescue StandardError; end
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
      msg = (JSON.parse(line) rescue next)
      return msg if msg["id"] == id
    end
    nil
  end

  def notify(method, params = {})
    @in.write(JSON.generate(jsonrpc: "2.0", method: method, params: params) + "\n")
  end

  # Returns the RAW text payload of a tools/call (what the agent actually ingests).
  def call_text(tool, args, timeout: 20)
    msg = rpc("tools/call", { name: tool, arguments: args }, timeout: timeout)
    return nil unless msg && msg["result"]
    (msg.dig("result", "content") || []).map { |c| c["text"] }.compact.join
  end

  private

  def read_line(timeout)
    return nil if timeout <= 0
    @out.gets if IO.select([@out], nil, nil, timeout)
  rescue StandardError
    nil
  end
end

# ---- sample real (class, file) pairs, seeded + deterministic ----------------
def gather(root, max)
  Dir.glob(File.join(root, "**/*.rb")).reject do |p|
    rel = p.sub(/\A#{Regexp.escape(root)}\/?/, "")
    rel =~ %r{(\A|/)(node_modules|log|\.git|tmp|vendor)(/|\z)} ||
      File.size(p) > 80_000 || File.size(p) < 300
  end.sort_by { |p| Digest::SHA1.hexdigest("#{SEED}:#{p}") }.first(max)
end

files = gather(ROOT, 400)
abort "no .rb under #{ROOT}" if files.empty?

pairs = [] # [class_name, abs_path]
names = []
files.each do |p|
  File.foreach(p) do |line|
    if (m = line.match(/^\s*(?:class|module)\s+([A-Z][A-Za-z0-9_]*)/))
      pairs << [m[1], p]
      names << m[1]
    end
  end
rescue StandardError
end
pairs = pairs.uniq { |c, _| c }.sort_by { |c, _| Digest::SHA1.hexdigest("#{SEED}:#{c}") }.first(N)
names = names.uniq.sort_by { |x| Digest::SHA1.hexdigest("#{SEED}:m#{x}") }.first(N)
rel = ->(p) { p.sub(/\A#{Regexp.escape(ROOT)}\/?/, "") }

# ---- baseline helpers (what a refract-less agent ingests) -------------------
def file_bytes(path)
  File.size(path)
rescue StandardError
  0
end

# grep the repo for a bare name the way an agent hunting references would.
def grep_bytes(root, name)
  out, = Open3.capture2e("grep", "-rn", "--include=*.rb", "-F", name, root)
  out.bytesize
rescue StandardError
  0
end

mcp = Mcp.new([REFRACT, "--mcp", "--disable-rubocop"], ROOT)
mcp.start

# wait for the index to answer
ready = false
60.times do
  r = mcp.call_text("workspace_symbols", { "query" => (names.first || "A")[0, 3] }, timeout: 8)
  if r && r.length > 2
    ready = true
    break
  end
  sleep 0.3
end
warn("index never became ready") unless ready

# ---- tasks ------------------------------------------------------------------
# each task accumulates {mcp_bytes, base_bytes, n} over the sample
tasks = {
  "class_summary"    => { desc: "understand a class's API", mcp: 0, base: 0, n: 0 },
  "get_file_overview" => { desc: "outline a file's symbols", mcp: 0, base: 0, n: 0 },
  "get_symbol_source" => { desc: "read one method's source", mcp: 0, base: 0, n: 0 },
  "find_references"  => { desc: "find all callers of a name", mcp: 0, base: 0, n: 0 },
}

# 1. class_summary(C)  vs  Read(file defining C)
pairs.each do |cname, path|
  t = mcp.call_text("class_summary", { "class_name" => cname }, timeout: 12)
  next unless t && !t.empty?
  tasks["class_summary"][:mcp]  += t.bytesize
  tasks["class_summary"][:base] += file_bytes(path)
  tasks["class_summary"][:n]    += 1
end

# 2. get_file_overview(F)  vs  Read(F)
pairs.map { |_, p| p }.uniq.first(N).each do |path|
  t = mcp.call_text("get_file_overview", { "file" => rel.call(path) }, timeout: 12)
  next unless t && !t.empty?
  tasks["get_file_overview"][:mcp]  += t.bytesize
  tasks["get_file_overview"][:base] += file_bytes(path)
  tasks["get_file_overview"][:n]    += 1
end

# 3. get_symbol_source(C, M)  vs  Read(file defining C)
#    M = a method name harvested from the class's own summary (first def line).
pairs.each do |cname, path|
  meth = nil
  begin
    File.foreach(path) do |line|
      if (m = line.match(/^\s*def\s+(?:self\.)?([a-z_][A-Za-z0-9_?!]*)/))
        meth = m[1]
        break
      end
    end
  rescue StandardError
  end
  next unless meth
  t = mcp.call_text("get_symbol_source", { "class_name" => cname, "method_name" => meth }, timeout: 12)
  next unless t && !t.empty? && !t.include?("not found")
  tasks["get_symbol_source"][:mcp]  += t.bytesize
  tasks["get_symbol_source"][:base] += file_bytes(path)
  tasks["get_symbol_source"][:n]    += 1
end

# 4. find_references(name)  vs  grep -rn name
names.first(N).each do |nm|
  t = mcp.call_text("find_references", { "name" => nm }, timeout: 12)
  next unless t && !t.empty?
  tasks["find_references"][:mcp]  += t.bytesize
  tasks["find_references"][:base] += grep_bytes(ROOT, nm)
  tasks["find_references"][:n]    += 1
end

mcp.stop

# ---- report -----------------------------------------------------------------
rows = tasks.map do |name, d|
  next if d[:n].zero?
  mcp_tok = est_tokens(d[:mcp])
  base_tok = est_tokens(d[:base])
  ratio = d[:mcp].zero? ? nil : (d[:base].to_f / d[:mcp]).round(1)
  {
    task: name, desc: d[:desc], n: d[:n],
    mcp_bytes: d[:mcp], base_bytes: d[:base],
    mcp_tokens: mcp_tok, base_tokens: base_tok,
    reduction_x: ratio,
    saved_tokens: base_tok - mcp_tok,
    saved_pct: base_tok.zero? ? nil : (100.0 * (base_tok - mcp_tok) / base_tok).round(1),
  }
end.compact

tot_mcp = rows.sum { |r| r[:mcp_tokens] }
tot_base = rows.sum { |r| r[:base_tokens] }
summary = {
  root: ROOT, sample_n: N, token_estimate: "chars/4",
  tasks: rows,
  totals: {
    mcp_tokens: tot_mcp, base_tokens: tot_base,
    overall_reduction_x: tot_mcp.zero? ? nil : (tot_base.to_f / tot_mcp).round(1),
    overall_saved_pct: tot_base.zero? ? nil : (100.0 * (tot_base - tot_mcp) / tot_base).round(1),
  },
}
puts JSON.pretty_generate(summary)
