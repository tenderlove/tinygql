require "tinygql/parser"
require "tinygql/version"

module TinyGQL
  require "tinygql/visitors"
  require "tinygql/expansion"
  require "tinygql/introspection"

  #: (String) -> Nodes::Document
  def self.parse doc
    Parser.new(doc).parse
  end

  # Parses a schema, adding the introspection types every schema has
  #: (String) -> Nodes::Document
  def self.parse_schema sdl
    parse(sdl + "\n" + INTROSPECTION)
  end
end
