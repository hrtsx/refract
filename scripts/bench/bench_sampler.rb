# frozen_string_literal: true

# Shared deterministic corpus sampler + percentile helpers, used by the realistic
# perf driver and the real-repo accuracy/DX drivers so they sample identically.

require "digest"

module BenchSampler
  module_function

  # Deterministically pick up to max_files .rb files from a repo, skipping vendored
  # / generated / trivial / oversized files. Order is a stable function of seed.
  def gather_files(root, seed:, max_files: 200)
    files = Dir.glob(File.join(root, "**/*.rb")).reject do |p|
      rel = p.sub(/\A#{Regexp.escape(root)}\/?/, "")
      rel =~ %r{(\A|/)(node_modules|log|\.git|tmp|vendor|spec/fixtures|db/migrate)(/|\z)} ||
        File.size(p) > 100_000 ||
        File.size(p) < 200
    end
    files.sort_by { |p| Digest::SHA1.hexdigest("#{seed}:#{p}") }.first(max_files)
  end

  # Pick [line, char] positions (0-indexed) where an identifier or method call is
  # likely: any `recv.meth` match yields a position on the receiver and one on the
  # method name. Deterministic subset of size max_positions.
  def pick_positions(text, seed:, max_positions: 20)
    positions = []
    text.each_line.with_index do |line, idx|
      line.scan(/\b([a-z_][a-zA-Z0-9_]*)\.([a-z_][a-zA-Z0-9_]*)/) do
        m = Regexp.last_match
        col = m.pre_match.length
        positions << [idx, col]
        positions << [idx, col + m[1].length + 1]
      end
    end
    return positions if positions.size <= max_positions
    positions.sort_by { |lc| Digest::SHA1.hexdigest("#{seed}:#{lc.join(",")}") }
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
end
