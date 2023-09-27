require "helper"
require "tinygql"

module TinyGQL
  class ParserTest < Test
    def test_homogeneous_ast
      %w{ kitchen-sink.graphql schema-extensions.graphql schema-kitchen-sink.graphql }.each do |f|
        ast = Parser.parse File.read(File.join(__dir__, f))
        assert ast.all? { |x| x.is_a?(TinyGQL::Nodes::Node) }
      end
    end

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

    def test_operation_definition_is_executable
      doc = <<-eod
mutation {
  likeStory(storyID: 12345) {
    story {
      likeCount
    }
  }
}
eod
      ast = TinyGQL.parse doc
      od = ast.find_all(&:operation_definition?)
      refute_predicate od, :empty?
      assert od.all?(&:executable_definition?)
    end

    def test_fragments_are_executable
      doc = <<-eod
query withFragments {
  user(id: 4) {
    friends(first: 10) {
      ...friendFields
    }
    mutualFriends(first: 10) {
      ...friendFields
    }
  }
}

fragment friendFields on User {
  id
  name
  profilePic(size: 50)
}
eod
      ast = TinyGQL.parse doc
      od = ast.find_all(&:fragment_definition?)
      refute_predicate od, :empty?
      assert od.all?(&:executable_definition?), "fragments should be executable"
    end

    def test_has_position_and_line
      doc = <<-eod
mutation {
  likeStory(sturyID: 12345) {
    story {
      likeCount
    }
  }
}
eod
      parser = Parser.new doc
      ast = parser.parse
      expected = ["likeStory", "story", "likeCount"].map { |str| doc.index(str) }
      assert_equal expected, ast.find_all(&:field?).map(&:start)
      assert_equal [2, 3, 4], ast.find_all(&:field?).map { |n| n.line(doc) }
    end

    def test_field_alias
      doc = <<-eod
mutation {
  a: likeStory(storyID: 12345) {
    b: story {
      c: likeCount
    }
  }
}
eod
      parser = Parser.new doc
      ast = parser.parse
      assert_equal ["likeStory", "story", "likeCount"], ast.find_all(&:field?).map(&:name)
      assert_equal ["a", "b", "c"], ast.find_all(&:field?).map(&:aliaz)
    end

    def test_shorthand
      doc = <<-eod
{
  field
}
eod
      parser = Parser.new doc
      ast = parser.parse
      assert_predicate ast.children.first, :operation_definition?
      assert_equal ["field"], ast.find_all(&:field?).map(&:name)
    end

    def test_kitchen_sink
      parser = Parser.new File.read(File.join(__dir__, "kitchen-sink.graphql"))
      parser.parse
    end

    def test_schema_kitchen_sink
      parser = Parser.new File.read(File.join(__dir__, "schema-kitchen-sink.graphql"))
      parser.parse
    end

    def test_visitor
      doc = <<-eod
mutation {
  a: likeStory(storyID: 12345) {
    b: story {
      c: likeCount
    }
  }
}
eod
      viz = Class.new do
        include TinyGQL::Visitors::Visitor

        attr_reader :nodes

        def initialize
          @nodes = []
        end

        def handle_field obj
          nodes << obj if obj.name == "likeStory"
          super
        end
      end
      parser = Parser.new doc
      ast = parser.parse
      obj = viz.new
      ast.accept(obj)
      assert_equal 1, obj.nodes.length
      node = obj.nodes.first
      assert_equal "a", node.aliaz
      assert_equal 1, node.arguments.length
    end

    def test_fold
      doc = <<-eod
mutation {
  a: likeStory(storyID: 12345) {
    b: story {
      c: likeCount
    }
  }
}
eod
      viz = Module.new do
        extend TinyGQL::Visitors::Fold

        def self.handle_field obj, nodes
          if obj.name == "likeStory"
            super(obj, nodes + [obj])
          else
            super
          end
        end
      end
      parser = Parser.new doc
      ast = parser.parse
      fields = ast.fold(viz, [])
      assert_equal 1, fields.length
      node = fields.first
      assert_equal "a", node.aliaz
      assert_equal 1, node.arguments.length
    end

    def test_null
      doc = <<-eod
mutation {
  a: likeStory(storyID: 12345) {
    b: story {
      c: likeCount
    }
  }
}
eod
      viz = Module.new do
        extend TinyGQL::Visitors::Null

        def self.handle_field obj
          true
        end
      end
      parser = Parser.new doc
      ast = parser.parse
      ast.each { |node|
        assert_equal(node.field?, !!node.accept(viz))
      }
    end

    def test_null_fold
      doc = <<-eod
mutation {
  a: likeStory(storyID: 12345) {
    b: story {
      c: likeCount
    }
  }
}
eod
      viz = Module.new do
        extend TinyGQL::Visitors::NullFold

        def self.handle_field obj, x
          x
        end
      end
      parser = Parser.new doc
      ast = parser.parse
      ast.each { |node|
        assert_equal(node.field?, !!node.fold(viz, true))
      }
    end

    def test_multiple_implements
      doc = <<-eod
type SomeType implements a, b, c {
}
eod
      parser = Parser.new doc
      ast = parser.parse
      node = ast.find(&:object_type_definition?).first
      assert_equal ["a", "b", "c"], node.implements_interfaces.map(&:name)
    end

    def test_multiple_implements_no_end
      doc = <<-eod
type SomeType implements a, b, c
eod
      parser = Parser.new doc
      ast = parser.parse
      node = ast.find(&:object_type_definition?).first
      assert_equal ["a", "b", "c"], node.implements_interfaces.map(&:name)
    end

    def test_schemas_have_descriptions
      doc = <<-eod
"foo bar"
schema {
  query: QueryType
  mutation: MutationType
}
      eod
      ast = TinyGQL::Parser.parse doc
      node = ast.find(&:schema_definition?)
      assert node
      assert_equal "foo bar", node.description.value
    end

    def test_directives_have_descriptions
      doc = <<-eod
"""neat!"""
directive @skip(if: Boolean!) on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT
      eod
      ast = TinyGQL::Parser.parse doc
      node = ast.find(&:directive_definition?)
      assert node
      assert_equal "neat!", node.description.value
      assert_equal ["FIELD", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"], node.directive_locations.map(&:name)
    end

    def test_scalar_schema_extensions
      ast = Parser.parse File.read(File.join(__dir__, "schema-extensions.graphql"))
      node = ast.find { |x| x.scalar_type_extension? && x.name == "PositiveInt" }
      assert node
      assert_equal 2, node.directives.length
    end

    def test_scalar_schema_extensions_no_directives
      ast = Parser.parse File.read(File.join(__dir__, "schema-extensions.graphql"))
      node = ast.find { |x| x.scalar_type_extension? && x.name == "Aaron" }
      assert node
      assert_nil node.directives
    end

    def test_interface_extension
      ast = Parser.parse File.read(File.join(__dir__, "schema-extensions.graphql"))
      node = ast.find { |x| x.interface_type_extension? && x.name == "NamedEntity" }
      assert node
      assert_nil node.directives
      assert node.fields_definition
    end

    def test_union_extension
      ast = Parser.parse File.read(File.join(__dir__, "schema-extensions.graphql"))
      node = ast.find { |x| x.union_type_extension? && x.name == "Cool" }
      assert node
      assert_equal 1, node.directives.length
      assert_equal "foo", node.directives.first.name
    end

    def test_enum_extension
      ast = Parser.parse File.read(File.join(__dir__, "schema-extensions.graphql"))
      assert ast.find { |x| x.enum_type_extension? && x.name == "Direction" }
      assert ast.find { |x| x.enum_type_extension? && x.name == "AnnotatedEnum" }
      assert ast.find { |x| x.enum_type_extension? && x.name == "Neat" }
    end

    def test_input_extension
      ast = Parser.parse File.read(File.join(__dir__, "schema-extensions.graphql"))
      assert ast.find { |x| x.input_object_type_extension? && x.name == "InputType" }
      assert ast.find { |x| x.input_object_type_extension? && x.name == "AnnotatedInput" }
      assert ast.find { |x| x.input_object_type_extension? && x.name == "NeatInput" }
    end
  end
end
