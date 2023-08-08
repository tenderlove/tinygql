require "helper"

module TinyG
  class ParserTest < Test
    def test_multi_tok
      doc = <<-eod
mutation aaron($neat: Int = 123) @foo(lol: { lon: 456 }) {
}
eod
      parser = Parser.new doc
      ast = parser.parse
      assert_equal "mutation", ast.children.first.type
      mutation = ast.children.first
      assert_equal "aaron", mutation.name
      assert_equal 1, mutation.variable_definitions.length

      var_def = mutation.variable_definitions.first
      variable = var_def.variable
      assert_equal "neat", variable.name
      assert_equal "Int", var_def.type.name
      assert_equal "123", var_def.default_value.value

      assert_equal(["123", "456"], ast.find_all { |node| node.int_value? }.map(&:value))
    end

    def test_has_things
      doc = <<-eod
mutation {
  likeStory(storyID: 12345) {
    story {
      likeCount
    }
  }
}
eod
      parser = Parser.new doc
      ast = parser.parse
      assert_equal ["likeStory", "story", "likeCount"], ast.find_all(&:field?).map(&:name)
    end

    def test_field_alias
      doc = <<-eod
mutation {
  a likeStory(storyID: 12345) {
    b story {
      c likeCount
    }
  }
}
eod
      parser = Parser.new doc
      ast = parser.parse
      assert_equal ["likeStory", "story", "likeCount"], ast.find_all(&:field?).map(&:name)
      assert_equal ["a", "b", "c"], ast.find_all(&:field?).map(&:aliaz)
    end
  end
end
