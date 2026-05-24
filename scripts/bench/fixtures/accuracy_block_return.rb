module AccuracyBlockReturn
  class BrService
    def map_strings
      [1, 2, 3].map { |x| x.to_s }
    end

    def tap_and_modify
      [].tap { |arr| arr.push(1) }
    end

    def then_transform
      5.then { |x| x * 2 }
    end

    def each_with_obj
      [1, 2].each_with_object([]) { |x, a| a.push(x) }
    end

    def lazy_map_force
      [1, 2, 3].lazy.map { |x| x * 2 }.force
    end

    def by_symbol_map
      [1, 2, 3].map(&:to_s)
    end

    def by_symbol_select
      ["a", "b"].select(&:upcase)
    end
  end
end
