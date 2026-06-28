class Account
  def balance; end
end

class Post
  def title; end
end

class Member
  has_many :posts
  belongs_to :account
  scope :active, -> { where(x: 1) }
end

m = Member.new
m.
Member.
m.posts.first.
