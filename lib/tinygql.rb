require "tinygql/parser"
require "tinygql/version"

module TinyGQL
  require "tinygql/visitors"
  require "tinygql/expansion"

  def self.parse doc
    Parser.new(doc).parse
  end
end
