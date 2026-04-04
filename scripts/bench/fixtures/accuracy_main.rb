require_relative "accuracy_lib"

module AccuracyMain
  class Service
    def call(name)
      AccuracyLib::Helper.greet(name)
    end

    def loud(s)
      s.to_s.upcase
    end
  end

  CONST = 42

  def self.entry
    Service.new.call("world")
  end
end
