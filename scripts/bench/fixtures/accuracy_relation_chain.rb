module AccuracyRelationChain
  class User
    def self.where(*); end
    def self.order(*); end
    def self.joins(*); end
    def self.find_by(*); end
    def self.pluck(*); end
    def self.first; end
    def self.last; end
  end

  class Post
    def self.where(*); end
    def self.includes(*); end
    def self.order(*); end
    def self.find; end
  end

  def test_chain_where_order
    User.where(active: true).order(:name).first
  end

  def test_chain_where_joins
    User.where(active: true).joins(:posts).last
  end

  def test_chain_includes_order
    Post.includes(:comments).order(:created_at).find
  end

  def test_chain_find_by
    User.where(role: :admin).find_by(email: "x@y")
  end

  def test_chain_pluck
    User.where(active: true).pluck(:email)
  end

  def test_chain_take
    User.where(deleted_at: nil).take
  end
end
