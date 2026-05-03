module AccuracyConcern
  module Timestampable
    extend ActiveSupport::Concern

    included do
      before_save :touch_timestamp
    end

    def touch_timestamp
      self.updated_at = Time.current
    end
  end

  module Searchable
    extend ActiveSupport::Concern

    included do
      scope :search, ->(term) { where("name LIKE ?", "%#{term}%") }
    end
  end

  class Article
    include Timestampable
    include Searchable
  end

  def test_concern
    article = Article.new
    article.touch_timestamp
  end
end
