#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregate realistic-bench JSON results into comparison tables.
# Usage: realistic_aggregate.rb <dir>
# Reads all <corpus>__<server>__<workload>[__rubocop-X].json under <dir>
# and prints per-workload markdown tables.

require "json"

dir = ARGV[0] or abort "usage: #{$PROGRAM_NAME} <results-dir>"
files = Dir.glob(File.join(dir, "*.json")).sort
abort "no JSON files in #{dir}" if files.empty?

cells = []
files.each do |f|
  base = File.basename(f, ".json")
  text = File.read(f)
  begin
    data = JSON.parse(text)
  rescue JSON::ParserError
    warn "skipping malformed: #{f} (#{text.bytesize} bytes)"
    next
  end
  parts = base.split("__")
  corpus = parts[0]
  server = parts[1]
  workload = parts[2]
  rubocop = parts[3]&.sub(/^rubocop-/, "")
  cells << data.merge(
    "corpus" => corpus,
    "server" => server,
    "workload" => workload,
    "rubocop" => rubocop,
    "label" => server + (rubocop ? " (rb=#{rubocop})" : ""),
  )
end

def fmt(v)
  return "—" if v.nil?
  v.is_a?(Numeric) ? format("%.1f", v) : v.to_s
end

def metric(cell, *path)
  v = cell
  path.each { |k| v = v.is_a?(Hash) ? v[k.to_s] : nil }
  v
end

corpora = cells.map { |c| c["corpus"] }.uniq
workloads = cells.map { |c| c["workload"] }.uniq

puts "# Realistic bench results — #{File.basename(dir)}"
puts

corpora.each do |corpus|
  puts "## Corpus: `#{corpus}`"
  puts
  workloads.each do |wl|
    rows = cells.select { |c| c["corpus"] == corpus && c["workload"] == wl }
    next if rows.empty?
    puts "### Workload: `#{wl}`"
    puts
    if wl == "session"
      puts "| server | init ms | warm ms | rss MB | hover p50/p95 | def p50/p95 | comp p50/p95 | sym p50/p95 | refs p50/p95 | docSym p50 | rename p50 | diag-1st p50/p95 | diag-settle p50/p95 |"
      puts "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
      rows.each do |c|
        puts "| #{c["label"]} | #{fmt(c["initialize_ms"])} | #{fmt(c["warmup_first_def_ms"])} | #{fmt(c["peak_rss_mb"])} | #{fmt(metric(c, "per_method", "hover", "p50_ms"))}/#{fmt(metric(c, "per_method", "hover", "p95_ms"))} | #{fmt(metric(c, "per_method", "definition", "p50_ms"))}/#{fmt(metric(c, "per_method", "definition", "p95_ms"))} | #{fmt(metric(c, "per_method", "completion", "p50_ms"))}/#{fmt(metric(c, "per_method", "completion", "p95_ms"))} | #{fmt(metric(c, "per_method", "symbol", "p50_ms"))}/#{fmt(metric(c, "per_method", "symbol", "p95_ms"))} | #{fmt(metric(c, "per_method", "references", "p50_ms"))}/#{fmt(metric(c, "per_method", "references", "p95_ms"))} | #{fmt(metric(c, "per_method", "document_symbol", "p50_ms"))} | #{fmt(metric(c, "per_method", "rename", "p50_ms"))} | #{fmt(metric(c, "per_method", "diag_first_ms", "p50_ms"))}/#{fmt(metric(c, "per_method", "diag_first_ms", "p95_ms"))} | #{fmt(metric(c, "per_method", "diag_settle_ms", "p50_ms"))}/#{fmt(metric(c, "per_method", "diag_settle_ms", "p95_ms"))} |"
      end
    elsif wl == "typing"
      puts "| server | init ms | rss MB | hover p50/p95 | def p50/p95 | comp p50/p95 | didChange # |"
      puts "|---|---:|---:|---:|---:|---:|---:|"
      rows.each do |c|
        puts "| #{c["label"]} | #{fmt(c["initialize_ms"])} | #{fmt(c["peak_rss_mb"])} | #{fmt(metric(c, "per_method", "hover", "p50_ms"))}/#{fmt(metric(c, "per_method", "hover", "p95_ms"))} | #{fmt(metric(c, "per_method", "definition", "p50_ms"))}/#{fmt(metric(c, "per_method", "definition", "p95_ms"))} | #{fmt(metric(c, "per_method", "completion", "p50_ms"))}/#{fmt(metric(c, "per_method", "completion", "p95_ms"))} | #{fmt(metric(c, "per_method", "didchange_count"))} |"
      end
    else # micro
      puts "| server | init ms | warm ms | rss MB | hover p50/p95/p99 | def p50/p95/p99 | comp p50/p95/p99 |"
      puts "|---|---:|---:|---:|---:|---:|---:|"
      rows.each do |c|
        puts "| #{c["label"]} | #{fmt(c["initialize_ms"])} | #{fmt(c["warmup_first_def_ms"])} | #{fmt(c["peak_rss_mb"])} | #{fmt(metric(c, "per_method", "hover", "p50_ms"))}/#{fmt(metric(c, "per_method", "hover", "p95_ms"))}/#{fmt(metric(c, "per_method", "hover", "p99_ms"))} | #{fmt(metric(c, "per_method", "definition", "p50_ms"))}/#{fmt(metric(c, "per_method", "definition", "p95_ms"))}/#{fmt(metric(c, "per_method", "definition", "p99_ms"))} | #{fmt(metric(c, "per_method", "completion", "p50_ms"))}/#{fmt(metric(c, "per_method", "completion", "p95_ms"))}/#{fmt(metric(c, "per_method", "completion", "p99_ms"))} |"
      end
    end
    puts
  end
end
