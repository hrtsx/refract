module AccuracyPatternAdvanced
  def match_hash_keys(data)
    case data
    in {x:, y:}
      x + y
    end
  end

  def match_array_unpack(arr)
    case arr
    in [first, *rest]
      rest
    end
  end

  def match_class_pattern(obj)
    case obj
    in String => s
      s.upcase
    end
  end

  def match_nested_hash(data)
    case data
    in {user: {name:, age:}}
      name
    end
  end

  def match_with_guard(val)
    case val
    in Integer if val > 0
      val * 2
    end
  end

  def match_alternative(x)
    case x
    in 1 | 2 | 3
      "small"
    end
  end

  def test_patterns
    match_hash_keys({x: 1, y: 2})
    match_array_unpack([1, 2, 3])
    match_class_pattern("hello")
    match_nested_hash({user: {name: "Alice", age: 30}})
    match_with_guard(5)
    match_alternative(2)
  end
end
