#!/usr/bin/env ruby
# frozen_string_literal: true

# Direct completion probe at AR-generated-method call sites. Opens the model +
# usage files, warms, then asks each server whether the actually-called method is
# offered at the receiver's dot. Usage: c2_probe.rb <ROOT> <name> <cmd...>

require_relative "lsp_driver_lib"

ROOT = ARGV[0]
name = ARGV[1]
cmd  = ARGV[2..]

# [file, 0-idx line, char (just after the dot), expected method]
D = (ENV["LINE_OFFSET"] || "0").to_i # +1 once `# typed: true` is prepended
PROBES = [
  ["app/models/usage.rb", 3 + D, 6, "name"],          # column
  ["app/models/usage.rb", 4 + D, 6, "email"],         # column
  ["app/models/usage.rb", 5 + D, 6, "full_name"],     # alias_attribute
  ["app/models/usage.rb", 6 + D, 6, "posts"],         # has_many
  ["app/models/usage.rb", 8 + D, 6, "title"],         # column (Post)
  ["app/models/usage.rb", 10 + D, 6, "user"],         # belongs_to
  ["app/models/usage.rb", 11 + D, 18, "title"],       # u.posts.first.title chain
  ["app/models/usage.rb", 12 + D, 6, "created_at"],   # timestamp column
]

OPEN = %w[app/models/usage.rb app/models/user.rb app/models/post.rb db/schema.rb]

Dir.chdir(ROOT) # so `bundle exec <server>` finds the app's Gemfile/RBI
client = LspClient.new(name, cmd, root: ROOT)
client.start
client.initialize!
uris = {}
OPEN.each do |f|
  abs = File.join(ROOT, f)
  uris[f] = client.did_open(abs, File.read(abs)) if File.exist?(abs)
end
sleep((ENV["WARM"] || "10").to_i)

hits = 0
PROBES.each do |file, line, char, expected|
  uri = uris[file]
  labels = []
  5.times do
    r = client.completion_dot(uri, line, char, timeout: 15)
    res = r && r["result"]
    items = res.is_a?(Hash) ? (res["items"] || []) : Array(res)
    labels = items.map { |i| i["label"] || i["insertText"] }.compact
    break if labels.include?(expected)
    sleep 0.6
  end
  ok = labels.include?(expected)
  hits += 1 if ok
  puts "#{ok ? 'HIT ' : 'MISS'} #{expected.ljust(12)} (#{labels.size} offered)"
end
client.stop
puts "#{name}: #{hits}/#{PROBES.size} = #{(hits.to_f / PROBES.size).round(3)}"
