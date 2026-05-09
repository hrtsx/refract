module AccuracyStructData
  Point = Struct.new(:x, :y)

  def test_struct
    p = Point.new(1, 2)
    p.x
  end

  Person = Data.define(:name, :age)

  def test_data
    person = Person.new(name: "Alice", age: 30)
    person.name
  end

  def test_frozen_struct
    frozen = Struct.new(:value) do
      def frozen?
        true
      end
    end
    f = frozen.new(42)
    f.value
  end

  def test_data_pattern
    person = Person.new(name: "Bob", age: 25)
    case person
    in Person(name: n, age: a)
      n
    end
  end
end
