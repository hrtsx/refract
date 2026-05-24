module AccuracyAssocExtended
  class ExArticle
    has_many :comments, as: :commentable
    belongs_to :author, class_name: "ExUser"
  end

  class Video
    has_many :comments, as: :commentable
  end

  class ExComment
    belongs_to :commentable, polymorphic: true
    belongs_to :user
  end

  class ExUser
    has_many :posts
    has_many :comments
    has_many :articles, through: :comments, source: :article
  end

  class ExPost
    belongs_to :user
    has_many :reactions
  end

  class Reaction
    belongs_to :post
  end

  def test_associations
    user = ExUser.first
    user.posts
    user.comments
    user.articles
    article = ExArticle.first
    article.comments
    article.author
    comment = ExComment.first
    comment.commentable
    post = ExPost.first
    post.reactions
  end
end
