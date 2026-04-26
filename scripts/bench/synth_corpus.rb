#!/usr/bin/env ruby
# frozen_string_literal: true

# Synthetic 100k-file Ruby corpus generator. Shopify-shape: deeply nested
# namespaces, ActiveRecord-heavy, RSpec specs paired 1:1 with models.
#
# Usage:
#   scripts/bench/synth_corpus.rb <out-dir> [file-count]
#
# Defaults: out-dir required, file-count = 100000.
# Determinism: seed = git short SHA (or 1 if not in a git tree).

require "fileutils"

OUT = ARGV.fetch(0) { abort("usage: synth_corpus.rb <out-dir> [n]") }
N = (ARGV[1] || "100000").to_i
SEED = (`git rev-parse --short=8 HEAD 2>/dev/null`.strip.to_i(16).nonzero?) || 1
srand(SEED)

FileUtils.mkdir_p(File.join(OUT, "app/models"))
FileUtils.mkdir_p(File.join(OUT, "spec/models"))
FileUtils.mkdir_p(File.join(OUT, "lib"))

# Half models, half specs. ~10% extra in lib/ for utilities.
MODELS = (N * 0.45).to_i
SPECS = (N * 0.45).to_i
LIBS = N - MODELS - SPECS

ASSOC_VERBS = %w[has_many has_one belongs_to has_and_belongs_to_many]
VALID_VERBS = %w[validates validates_presence_of validates_uniqueness_of validates_length_of]
SCOPE_NAMES = %w[active recent latest popular pending archived published]

def model_namespace(idx)
  depth = (idx % 4) + 1
  segs = (1..depth).map { |d| "Mod#{(idx + d) % 50}" }
  segs.join("::")
end

def model_body(class_name, idx)
  assoc_count = (idx % 6) + 1
  assocs = assoc_count.times.map do |a|
    verb = ASSOC_VERBS[(idx + a) % ASSOC_VERBS.length]
    target = ":item_#{(idx + a) % 200}"
    "  #{verb} #{target}"
  end
  validates = ((idx % 4) + 1).times.map do |v|
    verb = VALID_VERBS[v % VALID_VERBS.length]
    "  #{verb} :name, presence: true"
  end
  scopes = ((idx % 3) + 1).times.map do |s|
    "  scope :#{SCOPE_NAMES[s % SCOPE_NAMES.length]}, -> { where(state: :ok) }"
  end
  methods = ((idx % 5) + 2).times.map do |m|
    <<~METHOD
        def method_#{m}(arg)
          arg.to_s + "_#{idx}"
        end
    METHOD
  end
  <<~RUBY
    # frozen_string_literal: true

    class #{class_name} < ApplicationRecord
    #{(assocs + validates + scopes).join("\n")}

    #{methods.join("\n")}
    end
  RUBY
end

def spec_body(class_name, idx)
  examples = ((idx % 4) + 2).times.map do |e|
    <<~EX
        it "behaves correctly (case #{e})" do
          subject = described_class.new
          expect(subject.method_0("x")).to eq("x_#{idx}")
        end
    EX
  end
  <<~RUBY
    # frozen_string_literal: true

    require "rails_helper"

    RSpec.describe #{class_name} do
    #{examples.join("\n")}
    end
  RUBY
end

def lib_body(name, idx)
  ms = ((idx % 6) + 2).times.map do |m|
    "  def self.helper_#{m}(arg); arg.to_s; end"
  end
  <<~RUBY
    # frozen_string_literal: true

    module #{name}
    #{ms.join("\n")}
    end
  RUBY
end

written = 0
MODELS.times do |i|
  ns = model_namespace(i)
  cls = "Model#{i}"
  fqn = "#{ns}::#{cls}"
  rel = ns.gsub("::", "/").downcase
  dir = File.join(OUT, "app/models", rel)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "model_#{i}.rb"), model_body(fqn, i))
  written += 1
end

SPECS.times do |i|
  ns = model_namespace(i)
  fqn = "#{ns}::Model#{i}"
  rel = ns.gsub("::", "/").downcase
  dir = File.join(OUT, "spec/models", rel)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "model_#{i}_spec.rb"), spec_body(fqn, i))
  written += 1
end

LIBS.times do |i|
  name = "Util#{i}"
  File.write(File.join(OUT, "lib", "util_#{i}.rb"), lib_body(name, i))
  written += 1
end

puts "synth_corpus: wrote #{written} files to #{OUT} (seed #{SEED.to_s(16)})"
