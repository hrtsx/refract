module BenchFixture
  class Calculator
    def initialize(seed = 0)
      @seed = seed
    end

    def add(a, b)
      a + b + @seed
    end

    def multiply(a, b)
      a * b
    end

    def compute(x, y)
      sum = add(x, y)
      product = multiply(x, y)
      sum + product
    end
  end

  class Greeter
    def initialize(name)
      @name = name
    end

    def greet
      "hello, #{@name}"
    end
  end

  def self.run
    calc = Calculator.new(1)
    g = Greeter.new("world")
    [calc.compute(2, 3), g.greet]
  end
end
