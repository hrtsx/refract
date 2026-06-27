class Wallet
  def credit; end
end

class Customer
  def initialize
    @wallet = Wallet.new
  end
  attr_reader :wallet
end

cust = Customer.new
cust.wallet.
