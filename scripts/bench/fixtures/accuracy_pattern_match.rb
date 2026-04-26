module AccuracyPatternMatch
  class Service
    def match_record(obj)
      case obj
      in Foo => bar
        bar
      in {key: x}
        x
      in [a, *b]
        a
      in User(name: n)
        n
      end
    end

    def match_array
      case [1, 2, 3]
      in [first, *rest]
        rest
      end
    end

    def match_hash
      case {a: 1, b: 2}
      in {a: x, b: y}
        x + y
      end
    end
  end
end
