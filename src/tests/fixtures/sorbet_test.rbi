class Dog
  sig { params(times: Integer, loud: T::Boolean).returns(NilClass) }
  def bark(times, loud: false); end
end
