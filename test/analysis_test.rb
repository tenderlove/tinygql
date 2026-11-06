require "helper"
require "tinygql"
require "tinygql/generator"

module TinyGQL
  class AnalysisTest < Test
    SCHEMA = <<~GRAPHQL
      directive @cost(weight: String!) on FIELD_DEFINITION | OBJECT | SCALAR | ENUM

      scalar Money @cost(weight: "3")

      interface Node { id: ID! }

      type User implements Node {
        id: ID!
        name: String
        balance: Money
        friends(first: Int, last: Int): UserConnection!
        posts: [Post!]!
        avatar: Image @cost(weight: "2.5")
      }

      type Post implements Node {
        id: ID!
        title: String @cost(weight: "4")
        author: User!
      }

      type Image @cost(weight: "10") { url: String }

      type UserConnection { nodes: [User!]! pageInfo: PageInfo! }
      type PageInfo { hasNextPage: Boolean! }

      union SearchResult = User | Post

      type Query {
        me: User
        node(id: ID!): Node
        search: [SearchResult!]!
      }

      type Mutation { like(id: ID!): Post }
    GRAPHQL

    PARSER = Generator.new(TinyGQL.parse_schema(SCHEMA)).parser_class

    def test_composite_fields_cost_one_and_leaves_zero
      assert_analysis 1, 2, "{ me { id name } }"
      assert_analysis 3, 4, "{ me { posts { author { name } } } }"
      assert_analysis 0, 1, "{ __typename }"
    end

    def test_depth_counts_root_fields_as_one
      assert_analysis 1, 2, '{ __type(name: "User") { name } }'
      # Skipped fields don't count, and neither does a field that selects
      # nothing
      assert_analysis 1, 2, "{ me @skip(if: true) { posts { id } } me2: me { __typename } }"
      assert_analysis 1, 1, "{ me { posts @skip(if: true) { id } } }"
    end

    def test_abstract_types_cost_their_most_expensive_object_type
      # Post's author costs 1 plus its friends connection, more than anything on User
      assert_analysis 4, 5, "{ node(id: 1) { id ... on User { name } ... on Post { author { friends { nodes { id } } } } } }"
      assert_analysis 1, 2, "{ search { __typename } }"
    end

    def test_response_keys_merge
      assert_analysis 2, 3, "{ me { id } me { posts { id } } }"
      assert_analysis 3, 3, "{ me { id } a: me { posts { id } } }"
    end

    def test_fragments
      assert_analysis 2, 3, "{ me { ...F ...F } } fragment F on User { posts { title @skip(if: true) id } }"
      assert_analysis 2, 3, "{ ...Q } fragment Q on Query { me { ... on User { posts { id } } } }"
    end

    def test_skip_and_include_use_variables
      query = "query($big: Boolean!) { me { id posts @include(if: $big) { author { id } } } }"
      assert_analysis 3, 4, query, { "big" => true }
      assert_analysis 1, 2, query, { "big" => false }
    end

    def test_cost_directive_weights
      # Post.title has @cost(weight: "4"); Money and Image have type weights
      assert_analysis 6, 3, "{ me { posts { title } } }"
      assert_analysis 4, 2, "{ me { balance } }"
      # A field's own @cost wins over its type's, and fractions are kept
      assert_analysis 3.5, 3, "{ me { avatar { url } } }"
      assert_equal 4, PARSER::Costs.new.Post_title(nil, 0, nil)
    end

    def test_cost_weights_must_be_numbers
      ["\"x\"", "\"NaN\"", "\"Infinity\""].each do |weight|
        error = assert_raises(Schema::Error) { Generator.new(TinyGQL.parse_schema("type Query { a: Int @cost(weight: #{weight}) }")).parser_class }
        assert_includes error.message, "@cost weight must be"
      end
    end

    # Costs can be overridden per field, with the field's arguments
    class ConnectionCosts < PARSER::Costs
      def User_friends args, selections, context
        size = args.first || args.last || 0
        size > 0 ? 2 + selections * size : 2
      end

      def __typename(type, context) = context
    end

    def test_overriding_costs
      costs = ConnectionCosts.new
      # me 1 + friends (2 + 3 × (nodes 1 + pageInfo 1))
      assert_analysis 9, 4, "{ me { friends(first: 3) { nodes { id } pageInfo { hasNextPage } } } }", costs: costs
      assert_analysis 10, 4, "query($n: Int) { me { friends(last: $n) { nodes { id } } } }", { "n" => 7 }, costs: costs
      assert_analysis 3, 4, "{ me { friends { nodes { id } } } }", costs: costs
      # __typename's cost is overridable too, with the context
      assert_analysis 6, 2, "{ me { __typename } }", costs: costs, context: 5
    end

    def test_mutations
      assert_analysis 2, 3, "mutation { like(id: 1) { author { id } } }"
    end

    def test_operation_names
      doc = PARSER.parse("query A { me { id } } query B { me { posts { id } } }")
      assert_equal 1, PARSER.analyze(doc, PARSER.coerce(doc, {}, op: "A"), op: "A").cost
      assert_equal 2, PARSER.analyze(doc, PARSER.coerce(doc, {}, op: "B"), op: "B").cost
      assert_raises(Inputs::Error) { PARSER.analyze(doc, [], op: "C") }
    end

    def test_introspection
      analysis = analyze('{ __schema { types { name fields { name type { name } } } } }')
      assert_equal 4, analysis.cost
      assert_equal 5, analysis.depth
    end

    def test_analysis_is_frozen
      analysis = analyze("{ me { id } }")
      assert_predicate analysis, :frozen?
      assert_kind_of TinyGQL::Analysis, analysis
    end

    private

    def analyze query, variables = {}, costs: PARSER::Costs.new, context: nil
      doc = PARSER.parse(query)
      PARSER.analyze(doc, PARSER.coerce(doc, variables), costs: costs, context: context)
    end

    def assert_analysis cost, depth, query, variables = {}, costs: PARSER::Costs.new, context: nil
      analysis = analyze(query, variables, costs: costs, context: context)
      assert_equal cost, analysis.cost, "cost of #{query}"
      assert_equal depth, analysis.depth, "depth of #{query}"
    end
  end
end
