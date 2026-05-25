class Account2
  def balance; end
  def freeze!; end
end

class CompParamHost
  extend T::Sig
  sig { params(acct: Account2).void }
  def process(acct)
    acct.
  end
end
