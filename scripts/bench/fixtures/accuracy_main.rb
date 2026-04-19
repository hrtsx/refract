require_relative "accuracy_lib"
require_relative "accuracy_model"
require_relative "accuracy_helper"

module AccuracyMain
  class Service
    def call(name)
      AccuracyLib::Helper.greet(name)
    end

    def loud(s)
      s.to_s.upcase
    end

    def goodbye(name)
      AccuracyLib::Helper.farewell(name)
    end
  end

  CONST = 42

  def self.entry
    Service.new.call("world")
  end

  def self.constant_ref
    CONST + 1
  end

  class Worker
    include AccuracyHelper::Mixable

    def perform
      mixed_method
    end
  end

  class Manager < Service
    def supervise(name)
      call(name)
    end
  end

  def self.with_model
    post = AccuracyModel::Post.new
    post.author
    post.title.to_s.upcase
    AccuracyModel::Post.find_recent
  end

  def self.with_literals
    "hello".upcase
    [1, 2, 3].first
    {a: 1}.fetch(:a)
    42.to_s
    :foo.to_s
  end
end
