require "tinygql/parser"
require "tinygql/version"

module TinyGQL
  autoload :Visitors, "tinygql/visitors"
  autoload :Expansion, "tinygql/expansion"

  def self.parse doc
    Parser.new(doc).parse
  end
end
