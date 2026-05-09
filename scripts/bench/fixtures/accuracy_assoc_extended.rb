module AccuracyAssocExtended
  class Article
    has_many :comments, as: :commentable
    belongs_to :author, class_name: "User"
  end

  class Video
    has_many :comments, as: :commentable
  end

  class Comment
    belongs_to :commentable, polymorphic: true
    belongs_to :user
  end

  class User
    has_many :posts
    has_many :comments
    has_many :articles, through: :comments, source: :article
  end

  class Post
    belongs_to :user
    has_many :reactions
  end

  class Reaction
    belongs_to :post
  end

  def test_associations
    user = User.first
    user.posts
    user.comments
    user.articles
    article = Article.first
    article.comments
    article.author
    comment = Comment.first
    comment.commentable
  end
end
