class ApplicationRecord
end

class Widget < ApplicationRecord
  def custom_method; end
end

w = Widget.new
w.
