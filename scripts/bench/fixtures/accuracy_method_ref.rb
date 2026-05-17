module AccuracyMethodRef
  def double(n)
    n * 2
  end

  def stringify(n)
    n.to_s
  end

  def test_method_ref_map
    [1, 2, 3].map(&method(:double))
  end

  def test_method_ref_each
    [4, 5, 6].each(&method(:stringify))
  end
end
