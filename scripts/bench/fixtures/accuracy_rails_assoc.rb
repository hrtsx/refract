module AccuracyRailsAssoc
  class Post
    has_one :author
    has_many :comments
    has_many :comment_authors, through: :comments, source: :author
    belongs_to :user, polymorphic: true
  end

  class Comment
    belongs_to :post
    belongs_to :author, class_name: "User"
  end

  class User
    has_many :posts, as: :user
    has_many :comments, as: :author
  end

  def test_assoc
    post = Post.first
    post.author
    post.comments
    post.comment_authors
    post.user
  end
end
