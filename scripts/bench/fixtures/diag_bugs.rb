module DiagBugs
  class Calc
    def add(a, b)
      a + b
    end

    def add(a, b)
      a - b
    end

    def triple(a, b, c)
      a + b + c
    end

    def run
      x = nil
      x.length
      triple(1, 2)
      missing_helper(3)
      leftover = 42
      triple(1, 2, 3)
    end

    def scale(value, factor)
      value * 2
    end
  end
end
