module Chn
  class C
    def own_c; end
  end
  class B
    def to_c
      C.new
    end
  end
  class A
    def to_b
      B.new
    end
  end
end

a = Chn::A.new
a.to_b.to_c.
