require "tinygql/parser"
require "tinygql/version"

module TinyGQL
  autoload :Visitors, "tinygql/visitors"

  def self.parse doc
    Parser.new(doc).parse
  end
end
