module AccuracyBlockAdvanced
  def test_yield_self
    result = "hello".yield_self { |s| s.upcase }
    result
  end

  def test_yield_self_chain
    value = 5.yield_self { |n| n * 2 }.yield_self { |n| n + 1 }
    value
  end

  def test_proc_call
    add = Proc.new { |a, b| a + b }
    add.call(1, 2)
  end

  def test_lambda_call
    multiply = ->(x, y) { x * y }
    multiply.call(3, 4)
  end

  def test_each_with_object_sum
    result = [1, 2, 3].each_with_object([]) { |x, acc| acc << x * 2 }
    result
  end

  def test_where_then_chain
    nums = [1, 2, 3, 4, 5]
    filtered = nums.select { |n| n > 2 }.then { |a| a.map { |x| x * 2 } }
    filtered
  end
end
