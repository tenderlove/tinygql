require "helper"
require "tinygql"
require "tinygql/generator"

module TinyGQL
  class CoerceTest < Test
    SCHEMA = <<~GRAPHQL
      scalar DateTime

      enum Status { DRAFT PUBLISHED }

      input PostFilter {
        status: Status = PUBLISHED
        after: DateTime
        tags: [String!]
        and: [PostFilter!]
        range: Range = { from: 1 }
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
        "literal #{text}"
      end

      def coerce_value_DateTime value
        raise InvalidValue, "DateTime must be a string" unless value.is_a?(String)
        "value #{value}"
      end
    end

    POSTS = "query($ids: [ID!]!, $first: Int, $f: PostFilter) { posts(ids: $ids, first: $first, filter: $f) { id } }"

    def test_coerce
      vars = coerce(POSTS, {
        "ids" => [1, "2"],
        "first" => 5,
        "f" => { "status" => "DRAFT", "tags" => "a", "and" => [{ "after" => "2026" }] },
      })
      assert_equal ["1", "2"], vars[0]
      assert_equal 5, vars[1]
      range = { "from" => 1, "to" => 100 }
      assert_equal({
        "status" => "DRAFT",
        "tags" => ["a"],
        "and" => [{ "status" => "PUBLISHED", "after" => "value 2026", "range" => range }],
        "range" => range,
      }, vars[2])
    end

    def test_results_are_frozen
      vars = coerce(POSTS, { "ids" => [1], "f" => { "and" => [{}] } })
      assert_predicate vars, :frozen?
      assert_predicate vars[0], :frozen?
      assert_predicate vars[2], :frozen?
      assert_predicate vars[2]["and"], :frozen?
      assert_predicate vars[2]["and"][0]["range"], :frozen?
    end

    def test_missing_and_null_variables
      vars = coerce(POSTS, { "ids" => 1, "first" => nil })
      assert_equal ["1"], vars[0]
      assert_nil vars[1]
      # Not the same as null, so arguments can use their defaults
      assert_same Inputs::UNDEFINED, vars[2]
    end

    def test_variable_defaults
      query = "query($r: Range = { from: 2 }, $m: [[Int]] = 3, $s: Status = DRAFT, $f: Float = 1, $x: Int = null) { between(range: $r, matrix: $m, score: $f) { id } posts(ids: 1, first: $x, filter: { status: $s }) { id } }"
      assert_equal [{ "from" => 2, "to" => 100 }, [[3]], "DRAFT", 1.0, nil], coerce(query, {})
      # Explicit nulls are kept
      assert_equal [{ "from" => 3, "to" => nil }, [[1, nil]], "PUBLISHED", 2.0, 4],
        coerce(query, { "r" => { "from" => 3, "to" => nil }, "m" => [[1, nil]], "s" => "PUBLISHED", "f" => 2, "x" => 4 })
    end

    def test_custom_scalar_defaults_are_coerced_each_time
      parser = Generator.new(TinyGQL.parse_schema(<<~GRAPHQL)).parser_class
        scalar DateTime
        input I { at: DateTime = "2026", list: [DateTime] = ["a", "b"] }
        type Query { f(i: I): Int }
      GRAPHQL
      scalars = Class.new(parser::Scalars) do
        def coerce_literal_DateTime(kind, text) = [kind, text]
      end
      vars = parser.coerce(parser.parse("query($i: I) { f(i: $i) }"), { "i" => {} }, scalars: scalars.new)
      assert_equal({ "at" => [:STRING, "2026"], "list" => [[:STRING, "a"], [:STRING, "b"]] }, vars[0])
    end

    def test_invalid_variables
      assert_coerce_error "Variable $ids of required type [ID!]! was not provided", POSTS, {}
      assert_coerce_error "Variable $ids of non-null type [ID!]! must not be null", POSTS, { "ids" => nil }
      assert_coerce_error "Invalid value for variable $ids[1]: Expected non-nullable type ID! not to be null", POSTS, { "ids" => [1, nil] }
      assert_coerce_error "Invalid value for variable $ids[0]: ID cannot represent value: 1.5", POSTS, { "ids" => [1.5] }
      assert_coerce_error 'Invalid value for variable $first: Int cannot represent non-integer value: "1"', POSTS, { "ids" => 1, "first" => "1" }
      assert_coerce_error "Invalid value for variable $first: Int cannot represent non 32-bit signed integer value: 2147483648", POSTS, { "ids" => 1, "first" => 2**31 }
      assert_coerce_error "Invalid value for variable $f.and[1].status: Value NOPE does not exist in Status enum", POSTS, { "ids" => 1, "f" => { "and" => [{}, { "status" => "NOPE" }] } }
      assert_coerce_error "Invalid value for variable $f.status: Enum Status cannot represent non-string value: 1", POSTS, { "ids" => 1, "f" => { "status" => 1 } }
      assert_coerce_error "Invalid value for variable $f: Field nope is not defined by type PostFilter", POSTS, { "ids" => 1, "f" => { "nope" => 1 } }
      assert_coerce_error "Invalid value for variable $f.range: Field Range.from of required type Int! was not provided", POSTS, { "ids" => 1, "f" => { "range" => { "to" => 1 } } }
      assert_coerce_error "Invalid value for variable $f.and: Expected type PostFilter to be an object, found 1", POSTS, { "ids" => 1, "f" => { "and" => 1 } }
      assert_coerce_error "Invalid value for variable $f.after: DateTime must be a string", POSTS, { "ids" => 1, "f" => { "after" => 1 } }
      assert_coerce_error "Variables must be an object", POSTS, []
    end

    def test_builtin_values
      scalars = Scalars.new
      assert_equal 1.0, scalars.coerce_value_Float(1)
      assert_equal 1.5, scalars.coerce_value_Float(1.5)
      assert_raises(Scalars::InvalidValue) { scalars.coerce_value_Float(Float::NAN) }
      assert_raises(Scalars::InvalidValue) { scalars.coerce_value_Float("1") }
      assert_raises(Scalars::InvalidValue) { scalars.coerce_value_Int(1.0) }
      assert_raises(Scalars::InvalidValue) { scalars.coerce_value_Int(true) }
      assert_equal false, scalars.coerce_value_Boolean(false)
      assert_raises(Scalars::InvalidValue) { scalars.coerce_value_Boolean("true") }
      assert_equal "x", scalars.coerce_value_String("x")
      assert_raises(Scalars::InvalidValue) { scalars.coerce_value_String(1) }
      assert_equal "1", scalars.coerce_value_ID(1)
    end

    def test_unimplemented_custom_scalars_raise
      doc = PARSER.parse(POSTS)
      error = assert_raises(NotImplementedError) do
        PARSER.coerce(doc, { "ids" => 1, "f" => { "after" => "2026" } })
      end
      assert_includes error.message, "coerce_value_DateTime"
    end

    def test_operations
      doc = PARSER.parse("query A($a: Int) { posts(ids: 1, first: $a) { id } } query B($b: Int) { posts(ids: 1, first: $b) { id } }")
      assert_equal [1], PARSER.coerce(doc, { "a" => 1, "b" => 2 }, op: "A")
      assert_equal [nil, 2], PARSER.coerce(doc, { "a" => 1, "b" => 2 }, op: "B")
      error = assert_raises(Inputs::Error) { PARSER.coerce(doc, {}) }
      assert_includes error.message, "An operation name is required"
      error = assert_raises(Inputs::Error) { PARSER.coerce(doc, {}, op: "C") }
      assert_includes error.message, "Unknown operation C"
      assert_equal Inputs::EMPTY, PARSER.coerce(PARSER.parse("{ posts(ids: 1) { id } }"), nil)
    end

    def test_literals
      doc = PARSER.parse("query($to: Int, $i: Int) { between(range: { from: 1, to: $to }, matrix: [[$i]]) { id } }")
      range, matrix = doc.find_all(&:argument?).map(&:value)
      inputs = PARSER::Inputs.new(TestScalars.new)
      range_type = Nodes::NotNullType.new(0, Nodes::NamedType.new(0, "Range"))
      matrix_type = Nodes::ListType.new(0, Nodes::ListType.new(0, Nodes::NamedType.new(0, "Int")))

      vars = PARSER.coerce(doc, {}, scalars: TestScalars.new)
      # Missing variables are left out, and fields get their defaults
      assert_equal({ "from" => 1, "to" => 100 }, inputs.literal_value(range_type, range, vars))
      assert_equal [[nil]], inputs.literal_value(matrix_type, matrix, vars)

      vars = PARSER.coerce(doc, { "to" => 5, "i" => 6 }, scalars: TestScalars.new)
      assert_equal({ "from" => 1, "to" => 5 }, inputs.literal_value(range_type, range, vars))
      assert_equal [[6]], inputs.literal_value(matrix_type, matrix, vars)
    end

    private

    def coerce query, variables
      PARSER.coerce(PARSER.parse(query, scalars: TestScalars.new), variables, scalars: TestScalars.new)
    end

    def assert_coerce_error message, query, variables
      error = assert_raises(Inputs::Error) { coerce query, variables }
      assert_equal message, error.message
    end
  end
end
