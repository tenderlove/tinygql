require "tinygql/parser"

module TinyGQL
  def self.parse doc
    Parser.new(doc).parse
  end
end
