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

    def test_schema_extension
      ast = Parser.parse File.read(File.join(__dir__, "schema-extensions.graphql"))
      nodes = ast.find_all(&:schema_extension?)
      assert_equal 3, nodes.length

      directives_only, both, ops_only = nodes

      assert_equal ["onSchema"], directives_only.directives.map(&:name)
      assert_nil directives_only.root_operation_definitions

      assert_equal ["onSchema"], both.directives.map(&:name)
      assert_equal ["subscription"], both.root_operation_definitions.map(&:operation_type)
      assert_equal ["SubscriptionType"], both.root_operation_definitions.map { |x| x.named_type.name }

      assert_nil ops_only.directives
      assert_equal ["mutation"], ops_only.root_operation_definitions.map(&:operation_type)
    end

    def test_non_null_types
      ast = Parser.parse "type A { a: Int! b: [Int!]! c: Int }"
      a, b, c = ast.find(&:object_type_definition?).fields_definition.map(&:type)

      assert a.not_null_type?
      assert_equal "Int", a.type.name

      assert b.not_null_type?
      assert b.type.list_type?
      assert b.type.type.not_null_type?
      assert_equal "Int", b.type.type.type.name

      assert c.named_type?
    end

    def test_interface_implements_interfaces
      ast = Parser.parse "interface A implements B & C { a: Int }"
      node = ast.find(&:interface_type_definition?)
      assert_equal ["B", "C"], node.implements_interfaces.map(&:name)
    end

    def test_implements_leading_ampersand
      ast = Parser.parse "type A implements & B & C { a: Int }"
      node = ast.find(&:object_type_definition?)
      assert_equal ["B", "C"], node.implements_interfaces.map(&:name)
    end

    def test_implements_does_not_consume_next_definition
      ast = Parser.parse "type A implements B\ntype C { a: Int }"
      a, c = ast.definitions
      assert_equal ["B"], a.implements_interfaces.map(&:name)
      assert_equal "C", c.name
    end

    def test_union_leading_pipe
      ast = Parser.parse "union U = | A | B"
      node = ast.find(&:union_type_definition?)
      assert_equal ["A", "B"], node.union_member_types.map(&:name)
    end

    def test_repeatable_directive
      ast = Parser.parse "directive @a repeatable on FIELD\ndirective @b on FIELD"
      a, b = ast.definitions
      assert a.repeatable
      refute b.repeatable
    end

    def test_directive_locations_leading_pipe
      ast = Parser.parse "directive @a on | FIELD | VARIABLE_DEFINITION"
      node = ast.find(&:directive_definition?)
      assert_equal ["FIELD", "VARIABLE_DEFINITION"], node.directive_locations.map(&:name)
      assert node.directive_locations.all?(&:executable_directive_location?)
    end

    def test_variable_directives
      ast = Parser.parse "query Q($a: Int = 1 @foo, $b: Int) { a }"
      a, b = ast.find(&:operation_definition?).variable_definitions
      assert_equal ["foo"], a.directives.map(&:name)
      assert_nil b.directives
    end

    def test_keywords_as_names
      keywords = Lexer::KEYWORDS - ["on"]
      keywords.each do |kw|
        ast = Parser.parse "{ #{kw}(#{kw}: 1) #{kw}: a ...#{kw} }"
        field, aliased, spread = ast.find(&:operation_definition?).selection_set
        assert_equal kw, field.name
        assert_equal kw, field.arguments.first.name
        assert_equal kw, aliased.aliaz
        assert_equal kw, spread.fragment_name

        ast = Parser.parse "query #{kw} { a }\nfragment #{kw} on #{kw} { a }\ntype #{kw} { #{kw}: #{kw} }"
        op, frag, type = ast.definitions
        assert_equal kw, op.name
        assert_equal kw, frag.fragment_name
        assert_equal kw, frag.type_condition.named_type.name
        assert_equal kw, type.name
        assert_equal kw, type.fields_definition.first.name
        assert_equal kw, type.fields_definition.first.type.name
      end
    end

    def test_keywords_as_enum_values
      ast = Parser.parse "enum A { type query on }"
      node = ast.find(&:enum_type_definition?)
      assert_equal ["type", "query", "on"], node.enum_value_definition.map { |x| x.enum_value.value }

      ast = Parser.parse "{ a(b: type) }"
      value = ast.find(&:argument?).value
      assert value.enum_value?
      assert_equal "type", value.value
    end

    def test_reserved_names
      assert_raises(Parser::UnexpectedToken) { Parser.parse "fragment on on A { a }" }
      assert_raises(Parser::UnexpectedToken) { Parser.parse "enum A { true }" }
      assert_raises(Parser::UnexpectedToken) { Parser.parse "enum A { null }" }
    end

    def test_boolean_and_null_positions
      doc = "{ a(b: true, c: null) }"
      b, c = Parser.parse(doc).find_all(&:argument?).map(&:value)
      assert_equal doc.index("true"), b.start
      assert_equal doc.index("null"), c.start
    end
  end
end
