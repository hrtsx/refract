module AccuracyEnumerator
  def test_lazy_chain
    [1, 2, 3].lazy.map { |x| x * 2 }.force
  end

  def test_to_enum
    enum = [1, 2, 3].to_enum
    enum.each { |x| puts x }
  end

  def test_with_index
    ["a", "b", "c"].each.with_index { |v, i| v }
  end

  def test_zip
    [1, 2, 3].zip([4, 5, 6]) { |a, b| a + b }
  end

  def test_each_cons
    [1, 2, 3, 4, 5].each_cons(2) { |a, b| a }
  end

  def test_chain_multiple
    [1, 2, 3].lazy.select { |x| x > 1 }.map { |x| x * 2 }.force
  end
end
