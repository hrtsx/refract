#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregate real-repo accuracy + DX JSON into markdown tables.
# Reads <corpus>__accuracy.json and <corpus>__<server>__dx.json from a results dir.
#
# Usage: realistic_accuracy_aggregate.rb <results-dir>

require "json"

dir = ARGV[0] or abort "usage: realistic_accuracy_aggregate.rb <results-dir>"
abort "no such dir: #{dir}" unless File.directory?(dir)

acc = Dir.glob(File.join(dir, "*__accuracy.json")).sort.filter_map do |f|
  JSON.parse(File.read(f)) rescue nil
end
dx = Dir.glob(File.join(dir, "*__*__dx.json")).sort.filter_map do |f|
  JSON.parse(File.read(f)) rescue nil
end

fmt = ->(x) { x.nil? ? "-" : x }

puts "## Real-repo accuracy (consensus oracle: >=2 of 3 servers agree => truth)\n\n"
puts "Definition precision/recall. Ambiguous probes (no >=2 agreement) excluded from P/R and reported separately."
puts
puts "Also: rival-independent **structural** oracle — resolution rate (returned/probes) and"
puts "structural precision (of inspectable targets, fraction that actually declare the queried"
puts "name). This is the usable accuracy signal where a >=2 consensus is impossible (rivals"
puts "can't run). Dropped servers (hung/crashed) are noted per corpus."
puts
puts "| corpus | dropped | server | def P | def R | refs P | refs R | unique | resolution | struct P |"
puts "|---|---|---|--:|--:|--:|--:|--:|--:|--:|"
acc.each do |r|
  dropped = (r["dropped_servers"] || []).join(",")
  dropped = "-" if dropped.empty?
  r["servers"].each do |srv|
    d = r.dig("definition", srv) || {}
    rf = r.dig("references", srv) || {}
    st = r.dig("structural", srv) || {}
    uniq = r.dig("def_unique_only", srv) || 0
    puts "| #{r['corpus']} | #{dropped} | #{srv} | #{fmt.(d['precision'])} | #{fmt.(d['recall'])} | #{fmt.(rf['precision'])} | #{fmt.(rf['recall'])} | #{uniq} | #{fmt.(st['resolution_rate'])} | #{fmt.(st['structural_precision'])} |"
  end
end
puts
puts "Probes/oracle: " + acc.map { |r| "#{r['corpus']} #{r['def_probes']}p (consensus-resolvable #{r['def_oracle_resolvable']}, ambiguous #{r['def_ambiguous']})" }.join("; ")

puts "\n### Rename ↔ reference consistency (edits == own reference set)\n\n"
puts "| corpus | server | probes | consistent |"
puts "|---|---|--:|--:|"
acc.each do |r|
  (r["rename_consistency"] || {}).each do |srv, v|
    puts "| #{r['corpus']} | #{srv} | #{v['n']} | #{v['consistent']} |"
  end
end

audited = acc.select { |r| r["diagnostics_audit"] }
unless audited.empty?
  puts "\n### Diagnostic false-positive audit (presumed-correct real code)\n\n"
  puts "Semantic FP rate = bug-claim diagnostics (wrong-arity / undefined-method / nil-receiver)"
  puts "no rival flags, over all such refract diagnostics. Lint-only codes (unused-*) are refract"
  puts "features rivals lack, so they are reported but excluded from the FP rate."
  puts
  puts "FP rate is only valid where a rival ran (refract-only repos show `n/a` — every diag"
  puts "is trivially refract-only there, so the rate would be a meaningless 1.0)."
  puts
  puts "| corpus | rival-validated | semantic diags | semantic refract-only | semantic FP rate | total diags | refract-only by code |"
  puts "|---|:-:|--:|--:|--:|--:|---|"
  audited.each do |r|
    a = r["diagnostics_audit"]
    bycode = (a["refract_only_by_code"] || {}).map { |k, v| "#{k}:#{v}" }.join(", ")
    rv = a["rival_validated"] ? "yes" : "no"
    rate = a["semantic_fp_rate"].nil? ? "n/a" : a["semantic_fp_rate"]
    ronly = a["semantic_refract_only"].nil? ? "-" : a["semantic_refract_only"]
    puts "| #{r['corpus']} | #{rv} | #{a['semantic_total']} | #{ronly} | #{rate} | #{a['total_refract_diags']} | #{bycode} |"
  end
end

# Struct-precision miss samples — concrete oracle-rejected targets, to separate
# "wrong target" from "oracle too weak" when iterating on precision.
miss_rows = acc.flat_map do |r|
  (r["structural_misses"] || {}).flat_map do |srv, ms|
    Array(ms).first(4).map { |m| [r["corpus"], srv, m] }
  end
end
unless miss_rows.empty?
  puts "\n### Struct-precision miss samples (oracle-rejected targets)\n\n"
  puts "| corpus | server | name | probe | target | target line |"
  puts "|---|---|---|---|---|---|"
  miss_rows.each do |corpus, srv, m|
    tl = (m["target_line"] || "").to_s.gsub("|", "\\|")[0, 60]
    puts "| #{corpus} | #{srv} | #{m['name']} | #{m['probe']} | #{m['target']} | `#{tl}` |"
  end
end

unless dx.empty?
  puts "\n## Real-repo DX (cold init, time-to-first-correct, warm, resources)\n\n"
  puts "| corpus | server | cold init ms | first-correct p50/p95 | warm ms | idle ms | RSS MB | CPU ms | index KB | robust |"
  puts "|---|---|--:|--:|--:|--:|--:|--:|--:|:-:|"
  dx.sort_by { |r| [r["corpus"].to_s, r["name"].to_s] }.each do |r|
    fc = r["first_correct"] || {}
    rob = r["robustness"] || {}
    robust = (rob["survived_malformed"] && rob["still_serving_after"]) ? "yes" : "no"
    p50p95 = "#{fmt.(fc['p50_ms'])}/#{fmt.(fc['p95_ms'])}"
    puts "| #{r['corpus']} | #{r['name']} | #{fmt.(r['cold_init_ms'])} | #{p50p95} | #{fmt.(r['full_warm_ms'])} | #{fmt.(r['warmup_idle_ms'])} | #{fmt.(r['peak_rss_mb'])} | #{fmt.(r['cpu_total_ms'])} | #{fmt.(r['index_disk_kb'])} | #{robust} |"
  end
end
