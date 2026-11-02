require "helper"
require "tinygql/generator"

module TinyGQL
  class InputValuesTest < Test
    SCHEMA = <<~GRAPHQL
      scalar DateTime

      enum Status { DRAFT PUBLISHED }

      input PostFilter {
        status: Status
        after: DateTime
        tags: [String!]
        and: [PostFilter!]
      }

      input Range {
        from: Int!
        to: Int = 100
      }

      type Query {
        posts(filter: PostFilter, first: Int = 10, ids: [ID!]!): [Post!]!
        between(range: Range!, score: Float, flag: Boolean, matrix: [[Int]]): [Post!]!
      }

      type Post {
        id: ID!
      }
    GRAPHQL

    PARSER = Generator.new(TinyGQL.parse_schema(SCHEMA)).parser_class

    class TestScalars < PARSER::Scalars
      def coerce_literal_DateTime kind, text
        raise InvalidValue, "DateTime must be a string" unless kind == :STRING
        text
      end
    end

    def test_valid_values
      [
        '{ posts(ids: [1, "2"]) { id } }',
        "{ posts(ids: 1) { id } }",
        "{ posts(ids: [], first: -5) { id } }",
        "{ posts(ids: [1], first: null, filter: null) { id } }",
        '{ posts(ids: [1], filter: { status: DRAFT, tags: "a", and: [{ status: PUBLISHED }, { tags: ["b", "c"] }] }) { id } }',
        "{ between(range: { from: 1 }) { id } }",
        "{ between(range: { from: 1, to: null }, score: 1, flag: false) { id } }",
        "{ between(range: { from: 1 }, score: 1.5e3) { id } }",
        "{ between(range: { from: 1 }, matrix: [[1, null], null]) { id } }",
        "{ between(range: { from: 1 }, matrix: 1) { id } }",
      ].each { |query| assert PARSER.parse(query), query }
    end

    def test_scalars_and_enums_are_coerced
      doc = PARSER.parse('{ posts(ids: [1, "2"], first: -5, filter: { status: DRAFT, tags: "a" }) { id } between(range: { from: 1 }, score: 1, flag: false) { id } }')
      # Visitors don't go into list items, so read those directly
      ids = arguments(doc).first.value
      assert_equal ["1", "2"], ids.value.map(&:coerced)
      leaves = doc.find_all { |node| Nodes::Value === node && !node.list_value? && !node.null_value? }
      assert_equal [-5, "DRAFT", "a", 1, 1.0, false], leaves.map(&:coerced)
    end

    def test_lists_and_objects_are_not_coerced
      doc = PARSER.parse('{ posts(ids: [1], filter: { tags: ["a"] }) { id } }')
      assert_equal 3, doc.count { _1.list_value? || _1.object_value? }
      doc.each { assert_nil _1.coerced if _1.list_value? || _1.object_value? }
    end

    def test_single_values_for_lists_are_not_wrapped
      value = arguments(PARSER.parse("{ posts(ids: 1) { id } }")).first.value
      assert_predicate value, :int_value?
      assert_equal "1", value.coerced
    end

    def test_values_next_to_variables_are_coerced
      ids = arguments(PARSER.parse("query($id: ID!) { posts(ids: [$id, 2]) { id } }")).first.value
      id, two = ids.value
      assert_predicate id, :variable?
      assert_equal "2", two.coerced
    end

    def test_parsed_documents_are_shareable
      scalars = Class.new(PARSER::Scalars) do
        def coerce_literal_DateTime(kind, text) = Time.utc(*text.split("-").map(&:to_i))
      end
      doc = PARSER.parse('query($id: ID!) { posts(ids: [$id, 2], filter: { after: "2026-01-02", status: DRAFT }) { id } }', scalars: scalars.new)
      assert Ractor.shareable?(doc)
    end

    def test_custom_scalars_get_the_kind_of_literal
      kinds = []
      scalars = Class.new(PARSER::Scalars) do
        define_method(:coerce_literal_DateTime) { |kind, text| kinds << [kind, text]; text }
      end
      PARSER.parse('{ a: posts(ids: 1, filter: { after: "x\\ty" }) { id } b: posts(ids: 1, filter: { after: 5 }) { id } c: posts(ids: 1, filter: { after: 1.5 }) { id } d: posts(ids: 1, filter: { after: true }) { id } e: posts(ids: 1, filter: { after: NOW }) { id } }', scalars: scalars.new)
      assert_equal [[:STRING, "x\ty"], [:INT, "5"], [:FLOAT, "1.5"], [:BOOLEAN, "true"], [:ENUM, "NOW"]], kinds
    end

    def test_custom_scalars_get_list_and_object_nodes
      json = Generator.new(TinyGQL.parse_schema("scalar Json type Query { f(j: Json): Int }")).parser_class
      scalars = Class.new(json::Scalars) do
        # The unfrozen string checks that results are frozen all the way down
        def coerce_literal_Json(kind, value) = [kind, +value.class.name.split("::").last]
      end.new

      list, object = arguments(json.parse("{ a: f(j: [1, { b: 2 }]) b: f(j: { b: [3] }) }", scalars: scalars)).map(&:value)
      assert_equal [:LIST, "ListValue"], list.coerced
      assert_equal [:OBJECT, "ObjectValue"], object.coerced
      assert Ractor.shareable?(list.coerced)
      assert Ractor.shareable?(object.coerced)

      ["query($x: Int) { f(j: { b: $x }) }", "query($x: Int) { f(j: [1, [$x]]) }"].each do |query|
        error = assert_raises(ValidatingParser::ValidationError) { json.parse query, scalars: scalars }
        assert_includes error.message, "Invalid value for argument j on Query.f: Variables can't be used inside Json literals"
      end
      # A variable for the whole value is fine
      assert_predicate arguments(json.parse("query($x: Json) { f(j: $x) }", scalars: scalars)).first.value, :variable?
    end

    def test_coerced_custom_scalars
      scalars = Class.new(PARSER::Scalars) do
        def coerce_literal_DateTime(kind, text) = Time.utc(*text.split("-").map(&:to_i))
      end
      doc = PARSER.parse('{ posts(ids: 1, filter: { after: "2026-01-02" }) { id } }', scalars: scalars.new)
      after = doc.find { _1.object_field? && _1.name == "after" }.value
      assert_equal Time.utc(2026, 1, 2), after.coerced
      assert_predicate after.coerced, :frozen?
    end

    def test_schemaless_arguments_are_not_coerced
      arg = arguments(Parser.parse("{ a(b: 1) }")).first
      assert_nil arg.value.coerced
    end

    def test_allowed_variables
      [
        "query($ids: [ID!]!) { posts(ids: $ids) { id } }",
        "query($id: ID!) { posts(ids: [$id, 2]) { id } }",
        "query($s: Status, $r: Range!) { posts(ids: 1, filter: { status: $s }) { id } between(range: $r) { id } }",
        "query($from: Int!) { between(range: { from: $from }) { id } }",
        # Non-null variables fit nullable positions
        "query($first: Int!, $m: [[Int!]!]!) { posts(ids: 1, first: $first) { id } between(range: { from: 1 }, matrix: $m) { id } }",
        # Nullable variables fit non-null positions with a default
        "query($first: Int) { posts(ids: 1, first: $first) { id } }",
        "query($r: Range = { from: 1 }) { between(range: $r) { id } }",
        "query($ids: [ID!]! = [1]) { posts(ids: $ids) { id } }",
        # Directives aren't typed yet, but their variables must be defined
        "query($b: Boolean!) { posts(ids: 1) @include(if: $b) { id } }",
        # Variables in fragments belong to the operations that spread them
        "query A($x: Int) { ...F } query B($x: Int!) { ...F } fragment F on Query { posts(ids: 1, first: $x) { id } }",
        "query($x: Int) { ...F } fragment F on Query { ...G } fragment G on Query { posts(ids: 1, first: $x) { id } }",
        "query($x: Int) { ...F ...G } fragment F on Query { ...G } fragment G on Query { posts(ids: 1, first: $x) { id } }",
      ].each { |query| assert PARSER.parse(query), query }
    end

    def test_variables_must_fit_their_positions
      assert_error "Variable $x of type String used in position expecting Int", "query($x: String) { posts(ids: 1, first: $x) { id } }"
      assert_error "Variable $x of type ID used in position expecting ID! line: 2", "query($x: ID) {\n posts(ids: [$x]) { id } }"
      assert_error "Variable $x of type [ID] used in position expecting [ID!]!", "query($x: [ID] = [1]) { posts(ids: $x) { id } }"
      # Single values fit list positions, but variables don't
      assert_error "Variable $x of type ID! used in position expecting [ID!]!", "query($x: ID!) { posts(ids: $x) { id } }"
      assert_error "Variable $x of type [Int] used in position expecting Int", "query($x: [Int]) { posts(ids: 1, first: $x) { id } }"
      assert_error "Variable $x of type [Int] used in position expecting [[Int]]", "query($x: [Int]) { between(range: { from: 1 }, matrix: $x) { id } }"
      assert_error "Variable $x of type Int used in position expecting Int!", "query($x: Int) { between(range: { from: $x }) { id } }"
      assert_error "Variable $x of type Int used in position expecting Int!", "query($x: Int = null) { between(range: { from: $x }) { id } }"
      assert_error "Variable $x of type Range used in position expecting Range!", "query($x: Range) { between(range: $x) { id } }"
      assert_error "Variable $x of type Status used in position expecting DateTime", "query($x: Status) { posts(ids: 1, filter: { after: $x }) { id } }"
      assert_error "Variable $x of type Int used in position expecting Int!", "query A($x: Int) { ...F } fragment F on Query { between(range: { from: $x }) { id } }"
      assert_error "Variable $x of type Int used in position expecting Int!", "query A($x: Int!) { ...F } query B($x: Int) { ...F } fragment F on Query { between(range: { from: $x }) { id } }"
    end

    def test_variables_must_be_defined
      assert_error "Variable $x is not defined line: 1", "{ posts(ids: $x) { id } }"
      assert_error "Variable $y is not defined", "query($x: ID!) { posts(ids: $y) { id } }"
      assert_error "Variable $x is not defined", "{ posts(ids: 1) @include(if: $x) { id } }"
      assert_error "Variable $x is not defined by operation B", "query A($x: Int) { ...F } query B { ...F } fragment F on Query { posts(ids: 1, first: $x) { id } }"
      assert_error "Variable $x is not defined by operation A line: 2", "query A { ...F }\nfragment F on Query { ...G } fragment G on Query { posts(ids: 1, first: $x) { id } }"
    end

    def test_variables_must_be_used
      assert_error "Variable $x is never used", "query($x: Int) { posts(ids: 1) { id } }"
      assert_error "Variable $x is never used by operation B", "query A($x: Int) { ...F } query B($x: Int) { posts(ids: 1) { id } } fragment F on Query { posts(ids: 1, first: $x) { id } }"
    end

    def test_variables_are_numbered
      doc = PARSER.parse("query A($x: Int, $y: Int) { posts(ids: 1, first: $x) { id } ...F } query B($y: Int, $z: Int) { posts(ids: 1, first: $z) { id } ...F } fragment F on Query { between(range: { from: 1, to: $y }) { id } }")
      vars = doc.find_all(&:variable?)
      assert_equal %w{ x y x y z z y }, vars.map(&:name)
      assert_equal [0, 1, 0, 1, 2, 2, 1], vars.map(&:index)
      assert_predicate doc, :frozen?
    end

    def test_fragment_cycles
      assert_error "Fragment F spreads itself", "{ ...F } fragment F on Query { ...F }"
      assert_error "Fragment F spreads itself line: 3", "{ ...F }\nfragment F on Query { ...G }\nfragment G on Query { ...F }"
      # Even when no operation uses them
      assert_error "Fragment F spreads itself", "{ posts(ids: 1) { id } } fragment F on Query { ...G } fragment G on Query { ...F }"
    end

    def test_variable_definitions
      assert_error "Duplicate variable $x", "query($x: Int, $x: Int) { posts(ids: 1, first: $x) { id } }"
      assert_error "Variable $x cannot be of non-input type Post", "query($x: Post) { posts(ids: 1) { id } }"
      assert_error "Variable $x cannot be of non-input type [Nope!]", "query($x: [Nope!]) { posts(ids: 1) { id } }"
      assert_error "Invalid default value for $x: Variables can't be used in default values", "query($y: Int, $x: [Int] = [$y]) { posts(ids: 1, first: $y) { id } }"
    end

    def test_invalid_scalars
      {
        '{ posts(ids: 1, first: "10") { id } }' => "Invalid value for argument first on Query.posts: Int cannot represent non-integer value: \"10\"",
        "{ posts(ids: 1, first: 2147483648) { id } }" => "Int cannot represent non 32-bit signed integer value: 2147483648",
        "{ posts(ids: 1, first: 1.5) { id } }" => "Int cannot represent non-integer value: 1.5",
        "{ posts(ids: [true]) { id } }" => "ID cannot represent a non-string and non-integer value: true",
        "{ posts(ids: 1.5) { id } }" => "ID cannot represent a non-string and non-integer value: 1.5",
        "{ between(range: { from: 1 }, score: true) { id } }" => "Float cannot represent non numeric value: true",
        "{ between(range: { from: 1 }, flag: 1) { id } }" => "Boolean cannot represent a non boolean value: 1",
        "{ between(range: { from: 1 }, matrix: [[1, [2]]]) { id } }" => "Int cannot represent non-integer value: a list",
        '{ posts(ids: 1, filter: { tags: [ENUM] }) { id } }' => "String cannot represent a non string value: ENUM",
      }.each { |query, message| assert_error message, query }
    end

    def test_nulls
      assert_error "Invalid value for argument ids on Query.posts: Expected value of type [ID!]!, found null",
        "{ posts(ids: null) { id } }"
      assert_error "Expected value of type ID!, found null", "{ posts(ids: [1, null]) { id } }"
      assert_error "Expected value of type PostFilter!, found null",
        "{ posts(ids: 1, filter: { and: [null] }) { id } }"
      assert_error "Expected value of type Int!, found null", "{ between(range: { from: null }) { id } }"
    end

    def test_enums
      assert_error "Invalid value for argument filter on Query.posts: Value ARCHIVED does not exist in Status enum",
        "{ posts(ids: 1, filter: { status: ARCHIVED }) { id } }"
      assert_error 'Enum Status cannot represent non-enum value: "DRAFT"',
        '{ posts(ids: 1, filter: { status: "DRAFT" }) { id } }'
      assert_error "Value BAD does not exist in Status enum",
        "{ posts(ids: 1, filter: { and: [{ status: DRAFT }, { status: BAD }] }) { id } }"
    end

    def test_input_objects
      assert_error "Expected value of type PostFilter, found 1", "{ posts(ids: 1, filter: 1) { id } }"
      assert_error "Expected value of type PostFilter, found a list", "{ posts(ids: 1, filter: [{ tags: [] }]) { id } }"
      assert_error "Field nope is not defined by type PostFilter", "{ posts(ids: 1, filter: { nope: 1 }) { id } }"
      assert_error "There can be only one input field named tags",
        '{ posts(ids: 1, filter: { tags: "a", tags: "b" }) { id } }'
      assert_error "Invalid value for argument range on Query.between: Field Range.from of required type Int! was not provided",
        "{ between(range: { to: 1 }) { id } }"
    end

    def test_duplicate_arguments
      assert_error "Duplicate argument ids on Query.posts", "{ posts(ids: 1, ids: 2) { id } }"
    end

    def test_errors_report_the_argument_line
      assert_error "Invalid value for argument first on Query.posts: Int cannot represent non-integer value: true line: 3",
        "{\n  posts(ids: 1,\n    first: true) { id } }"
    end

    def test_unimplemented_custom_scalars_raise
      error = assert_raises(NotImplementedError) do
        PARSER.parse '{ posts(ids: 1, filter: { after: "2026-01-01" }) { id } }'
      end
      assert_includes error.message, "coerce_literal_DateTime is not implemented"

      # Custom scalars aren't called for nulls or variables
      assert PARSER.parse("query($t: DateTime) { posts(ids: 1, filter: { after: $t }) { id } posts(ids: 1, filter: { after: null }) { id } }")
    end

    def test_custom_scalars
      scalars = TestScalars.new
      assert PARSER.parse('{ posts(ids: 1, filter: { after: "2026-01-01" }) { id } }', scalars: scalars)
      assert PARSER.new('{ posts(ids: 1, filter: { after: "2026-01-01" }) { id } }', scalars: scalars).parse
      error = assert_raises(ValidatingParser::ValidationError) do
        PARSER.parse "{ posts(ids: 1, filter: { after: 5 }) { id } }", scalars: scalars
      end
      assert_includes error.message, "Invalid value for argument filter on Query.posts: DateTime must be a string"
    end

    def test_overriding_builtin_scalars
      big_ints = Class.new(PARSER::Scalars) do
        def coerce_literal_Int(text) = text.to_i
      end
      query = "{ posts(ids: 1, first: 2147483648) { id } }"
      assert_raises(ValidatingParser::ValidationError) { PARSER.parse query }
      assert PARSER.parse(query, scalars: big_ints.new)
    end

    def test_parsers_without_custom_scalars_define_scalars
      parser = Generator.new(TinyGQL.parse_schema("type Query { a(b: Int): Int }")).parser_class
      assert_equal TinyGQL::Scalars, parser::Scalars.superclass
      assert_error "Int cannot represent non-integer value: true", "{ a(b: true) }", parser
    end

    def test_enum_and_input_extensions
      parser = Generator.new(TinyGQL.parse_schema(<<~GRAPHQL)).parser_class
        enum E { A }
        extend enum E { B }
        input I { a: Int }
        extend input I { b: E! }
        type Query { f(i: I): Int }
      GRAPHQL
      assert parser.parse("{ f(i: { a: 1, b: B }) }")
      assert_error "Field I.b of required type E! was not provided", "{ f(i: { a: 1 }) }", parser
    end

    def test_builtin_literals
      scalars = Scalars.new
      assert_equal 1, scalars.coerce_literal_Int("1")
      assert_equal(-2**31, scalars.coerce_literal_Int("-2147483648"))
      assert_raises(Scalars::InvalidValue) { scalars.coerce_literal_Int("2147483648") }
      assert_equal 1.0, scalars.coerce_literal_Float("1")
      assert_equal 1.5, scalars.coerce_literal_Float("1.5")
      assert_equal "x", scalars.coerce_literal_String("x")
      assert_equal true, scalars.coerce_literal_Boolean("true")
      assert_equal false, scalars.coerce_literal_Boolean("false")
      assert_equal "1", scalars.coerce_literal_ID("1")
    end

    private

    def arguments doc
      doc.find_all(&:argument?)
    end

    def assert_error message, query, parser = PARSER
      error = assert_raises(ValidatingParser::ValidationError) { parser.parse query }
      assert_includes error.message, message
    end
  end
end
