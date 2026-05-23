# Fixtures for PR7 accuracy harness +12 cases.
# Each labelled comment marks the cursor target line for a goto-definition probe.
# Indentation + line numbers are part of the contract; keep them stable when
# updating cases in scripts/bench/lsp_accuracy.rb.

class Address                                                # L1  defclass
  attr_reader :street, :city                                 # L2
end                                                          # L3

class User                                                   # L5  defclass
  has_one_attached :avatar                                   # L6
  has_many_attached :photos                                  # L7
  composed_of :address, mapping: [%w[street street]]         # L8
  delegate :name, :email, to: :profile, prefix: true         # L9
  delegate :phone, to: :contact, prefix: :alt                # L10

  def profile; end                                           # L12  def
  def contact; end                                           # L13
end                                                          # L14

class TypedNarrow                                            # L16
  extend T::Sig                                              # L17

  def coerced(thing)                                         # L19
    s = T.let(thing, String)                                 # L20  expect: s → String
    n = T.cast(thing, Integer)                               # L21
    m = T.must(maybe_nil_thing)                              # L22
    s.upcase                                                 # L23  expect: upcase resolves
  end                                                        # L24

  def maybe_nil_thing; "x"; end                              # L26
end                                                          # L27

u = User.new                                                 # L29
u.profile_name                                               # L30  ← delegate prefix:true   probe
u.profile_email                                              # L31  ← delegate prefix:true   probe
u.alt_phone                                                  # L32  ← delegate prefix::alt   probe
u.address                                                    # L33  ← composed_of getter     probe
u.avatar                                                     # L34  ← has_one_attached getter probe
u.photos                                                     # L35  ← has_many_attached getter probe
