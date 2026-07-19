# typed: true

require "sorbet-runtime"

extend T::Sig

sig { params(name: String).returns(String) }
def greeting(name)
  123
end
