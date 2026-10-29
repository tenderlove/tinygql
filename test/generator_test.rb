require "helper"
require "tinygql/generator"

module TinyGQL
  class GeneratorTest < Test
    SCHEMA = <<~GRAPHQL
      type Query {
        user(id: ID!): User
        node(id: ID!): Node
        search(q: String, first: Int = 10): [SearchResult!]!
      }

      type Mutation {
        like(id: ID!): Post
      }

      interface Node { id: ID! }

      type User implements Node {
        id: ID!
        name: String
        friends(first: Int): [User!]!
      }

      type Post implements Node {
        id: ID!
        title: String
      }

      union SearchResult = User | Post
    GRAPHQL

    PARSER = Generator.new(SCHEMA).parser_class

    def test_parses_valid_queries
      [
        "{ user(id: 1) { id name friends(first: 2) { name } } }",
        "{ a: user(id: 1) { b: name } }",
        "query Q { node(id: 1) { id ... on User { name } ...P } } fragment P on Post { title }",
        "{ search { __typename ... on User { name } ... on Post { title } } }",
        "{ user(id: 1) { ...F } } fragment F on Node { id }",
        "{ user(id: 1) { ... @include(if: true) { name } } }",
        "mutation { like(id: 1) { title } }",
        "{ search(first: 1, q: \"x\") { __typename } }",
      ].each do |query|
        assert PARSER.parse(query)
      end
    end

    def test_introspection
      assert PARSER.parse(<<~GRAPHQL)
        {
          __schema { types { name fields(includeDeprecated: true) { name type { name ofType { name } } } } }
          __type(name: "User") { kind }
        }
      GRAPHQL
    end

    def test_same_ast_as_generic_parser
      query = "query Q($id: ID!) { user(id: $id) { name ... on User { id } ...F } } fragment F on User { friends { name } }"
      generic = Parser.parse(query).map { |n| [n.class, n.start] }
      generated = PARSER.parse(query).map { |n| [n.class, n.start] }
      assert_equal generic, generated
    end

    def test_fields_know_their_parent_type
      ast = PARSER.parse "{ user(id: 1) { name friends { id } } }"
      assert_equal [["user", "Query"], ["name", "User"], ["friends", "User"], ["id", "User"]],
        ast.find_all(&:field?).map { |f| [f.name, f.parent_type] }
    end

    def test_generic_parser_has_no_parent_type
      ast = Parser.parse "{ user { name } }"
      assert ast.find_all(&:field?).all? { |f| f.parent_type.nil? }
    end

    def test_unknown_field
      assert_error "Field nope does not exist on User line: 2", "{ user(id: 1) {\n nope } }"
    end

    def test_union_only_allows_typename
      assert_error "Field name does not exist on SearchResult", "{ search { name } }"
    end

    def test_missing_required_argument
      assert_error "Missing required argument id on Query.user", "{ user { id } }"
      assert_error "Missing required argument id on Query.user", "{ user() { id } }"
    end

    def test_unknown_argument
      assert_error "Unknown argument x on Query.user", "{ user(id: 1, x: 2) { id } }"
      assert_error "Unknown argument x on User.id", "{ user(id: 1) { id(x: 1) } }"
    end

    def test_leaf_and_composite_selection_sets
      assert_error "Field Query.user must have a selection set", "{ user(id: 1) }"
      assert_error "Field User.name cannot have a selection set", "{ user(id: 1) { name { x } } }"
    end

    def test_impossible_inline_fragment
      assert_error "Fragment on Post can never apply to User", "{ user(id: 1) { ... on Post { title } } }"
    end

    def test_impossible_fragment_spread
      assert_error "Fragment on Post can never apply to User",
        "{ user(id: 1) { ...F } } fragment F on Post { title }"
    end

    def test_spreads_between_abstract_types
      parser = Generator.new(<<~GRAPHQL).parser_class
        type Query { a: A }
        interface A { id: ID }
        interface B { id: ID }
        interface C { id: ID }
        type X implements A & B { id: ID }
        type Y implements C { id: ID }
        type Z { id: ID }
        union U = Y | X
        union V = Y
      GRAPHQL

      # A and B share X, and A and U share X
      assert parser.parse("{ a { ... on B { id } ... on U { __typename } } }")
      assert parser.parse("{ a { ...F } } fragment F on B { id }")
      assert parser.parse("{ a { ... on A { id } } }")

      # Object types inside abstract types, and abstract types inside objects
      assert parser.parse("{ a { ... on X { id ... on A { id } ... on U { __typename } } } }")

      [
        ["{ a { ... on C { id } } }", "A"],
        ["{ a { ... on V { __typename } } }", "A"],
        ["{ a { ...F } } fragment F on C { id }", "A"],
        ["{ a { ... on Y { id } } }", "A"],
        ["{ a { ... on X { ... on C { id } } } }", "X"],
        ["{ a { ... on X { ... on Y { id } } } }", "X"],
        # Z isn't part of any interface or union
        ["{ a { ... on Z { id } } }", "A"],
        ["{ a { ... on X { ... on Z { id } } } }", "X"],
      ].each do |query, parent|
        error = assert_raises(ValidatingParser::ValidationError) { parser.parse query }
        assert_includes error.message, "can never apply to #{parent}"
      end
    end

    def test_fragment_defined_after_use
      assert PARSER.parse("{ user(id: 1) { ...F } } fragment F on User { name }")
    end

    def test_unknown_fragment
      assert_error "Unknown fragment Missing", "{ user(id: 1) { ...Missing } }"
    end

    def test_duplicate_fragment
      assert_error "Duplicate fragment F",
        "fragment F on User { id } fragment F on User { id } { user(id: 1) { ...F } }"
    end

    def test_unknown_type_condition
      assert_error "Unknown type Nope", "{ user(id: 1) { ... on Nope { id } } }"
      assert_error "Unknown type Nope", "fragment F on Nope { id }"
    end

    def test_unsupported_operation
      assert_error "Schema does not support subscription operations", "subscription { x }"
    end

    def test_rejects_type_system_definitions
      assert_raises(ExecutableParser::UnexpectedToken) { PARSER.parse "type Foo { a: Int }" }
    end

    def test_generated_source_loads_standalone
      source = Generator.new(SCHEMA).generate("GeneratorTestParser")
      Object.class_eval source
      assert GeneratorTestParser.parse("{ user(id: 1) { name } }")
      assert_raises(ValidatingParser::ValidationError) { GeneratorTestParser.parse("{ nope }") }
    ensure
      Object.send(:remove_const, :GeneratorTestParser) if defined?(::GeneratorTestParser)
    end

    def test_schema_extensions_and_schema_definition
      parser = Generator.new(<<~GRAPHQL).parser_class
        schema { query: Root }
        type Root { a: Int }
        extend type Root { b: Thing }
        type Thing { c: Int }
        extend schema { mutation: Root }
      GRAPHQL
      assert parser.parse("{ a b { c } }")
      assert parser.parse("mutation { a }")
    end

    def test_schema_may_declare_builtin_scalars
      parser = Generator.new("scalar ID\nscalar String\ntype Query { a(id: ID): String }").parser_class
      assert parser.parse("{ a(id: 1) }")
      assert_raises(Schema::Error) { Generator.new("type ID { a: Int }\ntype Query { a: Int }") }
    end

    def test_schema_errors
      assert_raises(Schema::Error) { Generator.new("type Query { a: Missing }") }
      assert_raises(Schema::Error) { Generator.new("type Foo { a: Int }") }
      assert_raises(Schema::Error) { Generator.new("type Query { a: Int }\nextend type Nope { b: Int }") }
      assert_raises(Schema::Error) { Generator.new("type Query implements Query { a: Int }") }
    end

    def test_possible_types
      schema = Generator.new(SCHEMA).schema
      assert_equal ["User", "Post"], schema.possible_types("Node")
      assert_equal ["User", "Post"], schema.possible_types("SearchResult")
      assert_equal ["User"], schema.possible_types("User")
    end

    private

    def assert_error message, query
      error = assert_raises(ValidatingParser::ValidationError) { PARSER.parse query }
      assert_includes error.message, message
    end
  end
end
