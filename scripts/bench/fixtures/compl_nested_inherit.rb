module Xf
  class Base
    def inherited_a; end
    def inherited_b; end
  end
  class Child < Base
    def own_c; end
  end
end

c = Xf::Child.new
c.
