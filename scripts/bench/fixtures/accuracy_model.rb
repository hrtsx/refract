module AccuracyModel
  class Post
    attr_accessor :title, :author_id

    def author
      User.find(author_id)
    end

    def self.find_recent
      [new]
    end
  end

  class User
    def self.find(id)
      new
    end
  end
end
