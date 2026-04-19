module AccuracyHelper
  module Mixable
    def mixed_method
      "from mixin"
    end
  end

  def self.format(name)
    "[#{name}]"
  end
end
