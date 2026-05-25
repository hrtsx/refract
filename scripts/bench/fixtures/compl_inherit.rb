class CompBase
  def base_method; end
end

class CompDerived < CompBase
  def own_method; end
end

d = CompDerived.new
d.
