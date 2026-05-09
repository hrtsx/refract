module AccuracySplatKwargs
  def method_with_splat(*args)
    args.first
  end

  def method_with_kwargs(**opts)
    opts[:key]
  end

  def method_with_rest(*rest)
    rest.count
  end

  def unpack_array(*items)
    items.map(&:to_s)
  end

  def pass_through_kwargs(**kwargs)
    method_with_kwargs(**kwargs)
  end

  def test_splat_call
    method_with_splat(1, 2, 3)
    arr = [1, 2, 3]
    method_with_splat(*arr)
    method_with_kwargs(key: "value")
    opts = {key: "value"}
    method_with_kwargs(**opts)
  end
end
