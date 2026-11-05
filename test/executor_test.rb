require "helper"
require "tinygql"
require "tinygql/generator"

module TinyGQL
  class ExecutorTest < Test
    SCHEMA = <<~GRAPHQL
      scalar DateTime

      enum Status { DRAFT PUBLISHED }

      interface Node { id: ID! }

      type Post implements Node {
        id: ID!
        title: String!
        status: Status
        publishedAt: DateTime
        tags: [String!]
        author: User
        score(scale: Int = 2): Float
      }

      type User implements Node {
        id: ID!
        name: String
        posts(first: Int = 10, status: Status): [Post!]!
      }

      union SearchResult = Post | User

      input NewPost { title: String!, status: Status = DRAFT }

      type Query {
        posts(first: Int, ids: [ID!]): [Post]
        post(id: ID!): Post
        node(id: ID!): Node
        search: [SearchResult!]!
        required: Post!
      }

      type Mutation {
        createPost(post: NewPost!): Post!
      }
    GRAPHQL

    PARSER = Generator.new(TinyGQL.parse_schema(SCHEMA)).parser_class

    Post = Struct.new(:id, :title, :status, :publishedAt, :tags, :author, keyword_init: true)
    User = Struct.new(:id, :name, :posts, keyword_init: true)

    class TestScalars < PARSER::Scalars
      def coerce_result_DateTime value
        value.to_s
      end
    end

    class TestResolvers < PARSER::Resolvers
      attr_reader :calls

      def initialize posts, users
        @posts = posts
        @users = users
        @calls = []
      end

      def Query_posts obj, args, context
        @calls << args
        posts = @posts
        posts = posts.select { |p| args.ids.include?(p&.id) } if args.ids
        args.first ? posts.first(args.first) : posts
      end

      def Query_post obj, args, context
        @posts.find { |p| p&.id == args.id }
      end

      def Query_node obj, args, context
        (@posts + @users).find { |n| n&.id == args.id }
      end

      def Query_search obj, args, context
        [@posts[0], @users[0]]
      end

      def Query_required obj, args, context
        nil
      end

      def Post_score obj, args, context
        @calls << args
        args.scale * 1.5
      end

      def User_posts obj, args, context
        @calls << args
        obj.posts.first(args.first)
      end

      def Mutation_createPost obj, args, context
        @calls << args
        Post.new(id: "new", title: args.post.title, status: args.post.status)
      end

      def resolve_type_Node obj, context
        obj.is_a?(Post) ? "Post" : "User"
      end

      def resolve_type_SearchResult obj, context
        context[:types].fetch(obj.class)
      end
    end

    def setup
      super
      @alice = User.new(id: "u1", name: "Alice", posts: [])
      @posts = [
        Post.new(id: "1", title: "One", status: :PUBLISHED, publishedAt: 2026, tags: ["a"], author: @alice),
        Post.new(id: "2", title: "Two", status: "DRAFT", tags: []),
      ]
      @alice.posts.concat @posts
      @resolvers = TestResolvers.new(@posts, [@alice])
    end

    def test_fields
      assert_data({ "posts" => [
        { "id" => "1", "title" => "One", "status" => "PUBLISHED", "publishedAt" => "2026", "tags" => ["a"], "author" => { "name" => "Alice" } },
        { "id" => "2", "title" => "Two", "status" => "DRAFT", "publishedAt" => nil, "tags" => [], "author" => nil },
      ] }, "{ posts { id title status publishedAt tags author { name } } }")
    end

    def test_arguments
      assert_data({ "posts" => [{ "id" => "1" }] }, "{ posts(first: 1) { id } }")
      assert_data({ "posts" => [{ "id" => "2" }] }, 'query($ids: [ID!]) { posts(ids: $ids) { id } }', { "ids" => 2 })
      assert_equal [{ "first" => 1, "ids" => nil }, { "first" => nil, "ids" => ["2"] }], fields(@resolvers.calls)
      assert_kind_of PARSER::Arguments::Query_posts, @resolvers.calls[0]
      assert @resolvers.calls.all?(&:frozen?)
    end

    def test_argument_defaults
      assert_data({ "post" => { "score" => 3.0, "author" => { "posts" => [{ "score" => 6.0 }, { "score" => 6.0 }] } } },
        'query($n: Int, $s: Int) { post(id: 1) { score author { posts(first: $n) { score(scale: $s) } } } }',
        { "s" => 4 })
      # Missing variables get the argument's default, null doesn't
      assert_equal [{ "scale" => 2 }, { "first" => 10, "status" => nil }, { "scale" => 4 }, { "scale" => 4 }], fields(@resolvers.calls)
      assert_data({ "posts" => [{ "id" => "1" }, { "id" => "2" }] }, 'query($n: Int) { posts(first: $n) { id } }', {})
      assert_equal({ "first" => nil, "ids" => nil }, fields(@resolvers.calls.last))
    end

    def test_fields_without_arguments_get_nil
      resolvers = Class.new(TestResolvers) do
        def Post_title(obj, args, context) = args.inspect
      end.new(@posts, [@alice])
      assert_equal({ "data" => { "post" => { "title" => "nil" } } }, execute("{ post(id: 1) { title } }", resolvers: resolvers))
    end

    def test_aliases_and_merging
      assert_data({ "a" => { "id" => "1", "title" => "One" }, "b" => { "title" => "Two" } },
        "{ a: post(id: 1) { id } b: post(id: 2) { title } a: post(id: 1) { title } }")
    end

    def test_fragments
      query = <<~GRAPHQL
        { node(id: "u1") { id ...UserFields ... on Post { title } }
          search { __typename ... on Node { id } ...PostFields } }
        fragment UserFields on User { name ...UserFields2 }
        fragment UserFields2 on User { posts { id } }
        fragment PostFields on Post { title }
      GRAPHQL
      context = { types: { Post => "Post", User => "User" } }
      assert_data({
        "node" => { "id" => "u1", "name" => "Alice", "posts" => [{ "id" => "1" }, { "id" => "2" }] },
        "search" => [{ "__typename" => "Post", "id" => "1", "title" => "One" }, { "__typename" => "User", "id" => "u1" }],
      }, query, context: context)
    end

    def test_bad_resolved_types
      result = execute("{ search { __typename } }", context: { types: { Post => "Post", User => "Node" } })
      assert_nil result["data"]
      assert_equal [{ "message" => 'Abstract type SearchResult must resolve to one of its object types, got "Node"', "path" => ["search", 1] }], result["errors"]

      result = execute("{ search { __typename } }", context: { types: { Post => "Query", User => "User" } })
      assert_equal ["search", 0], result["errors"][0]["path"]
    end

    def test_unimplemented_resolve_type
      resolvers = Class.new(PARSER::Resolvers) do
        def Query_node(obj, args, context) = Object.new
      end.new
      error = assert_raises(NotImplementedError) do
        execute "{ node(id: 1) { id } }", resolvers: resolvers
      end
      assert_includes error.message, "resolve_type_Node"
    end

    def test_skip_and_include
      query = 'query($yes: Boolean!) { post(id: 1) { id @skip(if: $yes) title @include(if: $yes) ... @skip(if: true) { status } ...F @include(if: false) } } fragment F on Post { tags }'
      assert_data({ "post" => { "title" => "One" } }, query, { "yes" => true })
      assert_data({ "post" => { "id" => "1" } }, query, { "yes" => false })
    end

    def test_typename
      assert_data({ "__typename" => "Query", "post" => { "__typename" => "Post" } }, "{ __typename post(id: 1) { __typename } }")
    end

    def test_introspection_with_other_fields
      assert_data({ "__type" => { "name" => "Post" }, "post" => { "id" => "1" } }, "{ __type(name: \"Post\") { name } post(id: 1) { id } }")
    end

    def test_null_bubbles_to_nullable_parent
      @posts[1].title = nil
      result = execute("{ posts { id title } }")
      assert_equal({ "posts" => [{ "id" => "1", "title" => "One" }, nil] }, result["data"])
      assert_equal [{ "message" => "Cannot return null for non-nullable field Post.title", "path" => ["posts", 1, "title"] }], result["errors"]
    end

    def test_null_bubbles_to_data
      result = execute("{ post(id: 1) { id } required { id } }")
      assert_nil result["data"]
      assert_equal [{ "message" => "Cannot return null for non-nullable field Query.required", "path" => ["required"] }], result["errors"]
    end

    def test_list_item_errors
      @posts[0].tags = ["a", nil]
      @alice.posts << nil
      result = execute('{ post(id: 1) { tags } node(id: "u1") { ... on User { posts { id } } } }')
      assert_equal({ "post" => { "tags" => nil }, "node" => nil }, result["data"])
      assert_equal [
        { "message" => "Cannot return null for non-nullable field Post.tags", "path" => ["post", "tags", 1] },
        { "message" => "Cannot return null for non-nullable field User.posts", "path" => ["node", "posts", 2] },
      ], result["errors"]
    end

    def test_lists_can_be_enumerables
      collection = Class.new do
        include Enumerable

        def initialize(items) = @items = items
        def each(&) = @items.each(&)
      end
      resolvers = Class.new(TestResolvers) do
        define_method(:User_posts) { |obj, args, context| collection.new(obj.posts) }
      end.new(@posts, [@alice])
      @posts[0].tags = Set["a", "b"]
      result = execute('{ post(id: 1) { tags } node(id: "u1") { ... on User { posts { id } } } }', resolvers: resolvers)
      assert_equal({ "data" => { "post" => { "tags" => ["a", "b"] }, "node" => { "posts" => [{ "id" => "1" }, { "id" => "2" }] } } }, result)

      # NoMethodErrors from completing items aren't list errors
      broken = Class.new(resolvers.class) do
        def Post_id(obj, args, context) = obj.nope
      end.new(@posts, [@alice])
      error = assert_raises(NoMethodError) { execute('{ node(id: "u1") { ... on User { posts { id } } } }', resolvers: broken) }
      assert_equal :nope, error.name

      # Items are still checked and bubble nulls
      @alice.posts << nil
      result = execute('{ node(id: "u1") { ... on User { posts { id } } } }', resolvers: resolvers)
      assert_equal({ "node" => nil }, result["data"])
      assert_equal ["node", "posts", 2], result["errors"][0]["path"]
    end

    def test_resolver_errors
      resolvers = Class.new(TestResolvers) do
        def Post_status(obj, args, context) = raise(ExecutionError, "nope #{obj.id}")
      end.new(@posts, [@alice])
      result = execute("{ posts { id status } }", resolvers: resolvers)
      assert_equal({ "posts" => [{ "id" => "1", "status" => nil }, { "id" => "2", "status" => nil }] }, result["data"])
      assert_equal [
        { "message" => "nope 1", "path" => ["posts", 0, "status"] },
        { "message" => "nope 2", "path" => ["posts", 1, "status"] },
      ], result["errors"]
    end

    def test_other_errors_propagate
      resolvers = Class.new(TestResolvers) do
        def Post_status(obj, args, context) = raise(ArgumentError, "bug")
      end.new(@posts, [@alice])
      assert_raises(ArgumentError) { execute("{ posts { status } }", resolvers: resolvers) }
    end

    def test_invalid_results
      @posts[0].status = "NOPE"
      @posts[1].tags = "a"
      @alice.id = 1.5
      result = execute("{ posts { status tags } post(id: 1) { author { id } } }")
      assert_equal({ "posts" => [{ "status" => nil, "tags" => ["a"] }, { "status" => "DRAFT", "tags" => nil }], "post" => { "author" => nil } }, result["data"])
      assert_equal [
        { "message" => 'Enum Status cannot represent value: "NOPE"', "path" => ["posts", 0, "status"] },
        { "message" => "Expected a list for field Post.tags, got String", "path" => ["posts", 1, "tags"] },
        { "message" => "ID cannot represent value: 1.5", "path" => ["post", "author", "id"] },
      ], result["errors"]
    end

    def test_builtin_results
      scalars = Scalars.new
      assert_equal 2, scalars.coerce_result_Int(2.0)
      assert_raises(Scalars::InvalidValue) { scalars.coerce_result_Int(2.5) }
      assert_raises(Scalars::InvalidValue) { scalars.coerce_result_Int(2**31) }
      assert_equal 2.0, scalars.coerce_result_Float(2)
      assert_equal "DRAFT", scalars.coerce_result_String(:DRAFT)
      assert_equal "1", scalars.coerce_result_String(1)
      assert_raises(Scalars::InvalidValue) { scalars.coerce_result_String(nil.to_a) }
      assert_raises(Scalars::InvalidValue) { scalars.coerce_result_Boolean(1) }
      assert_equal "1", scalars.coerce_result_ID(1)
    end

    def test_mutations
      result = execute('mutation($t: String!) { a: createPost(post: { title: $t }) { id title status } b: createPost(post: { title: "b", status: PUBLISHED }) { title } }', { "t" => "a" })
      assert_equal({ "data" => {
        "a" => { "id" => "new", "title" => "a", "status" => "DRAFT" },
        "b" => { "title" => "b" },
      } }, result)
      assert_equal [{ "post" => { "title" => "a", "status" => "DRAFT" } }, { "post" => { "title" => "b", "status" => "PUBLISHED" } }], fields(@resolvers.calls)
      assert_kind_of PARSER::InputObjects::NewPost, @resolvers.calls[0].post
    end

    def test_operation_names
      doc = PARSER.parse("query A { post(id: 1) { id } } query B { post(id: 2) { id } }")
      result = PARSER.execute(doc, PARSER.coerce(doc, {}, op: "B"), resolvers: @resolvers, op: "B")
      assert_equal({ "data" => { "post" => { "id" => "2" } } }, result)
    end

    def test_root_value
      resolvers = Class.new(PARSER::Resolvers) do
        def resolve_type_Node(obj, context) = "Post"
      end.new
      root = Struct.new(:post).new(@posts[0])
      doc = PARSER.parse("{ post(id: 1) { id title } }")
      assert_equal({ "data" => { "post" => { "id" => "1", "title" => "One" } } }, PARSER.execute(doc, [], resolvers: resolvers, root: root))
    end

    def test_input_names_must_be_readers
      error = assert_raises(Schema::Error) do
        Generator.new(TinyGQL.parse_schema("input I { hash: Int } type Query { f(i: I): Int }")).parser_class
      end
      assert_equal "I.hash can't be a reader, it would replace Object#hash", error.message

      error = assert_raises(Schema::Error) do
        Generator.new(TinyGQL.parse_schema("type Query { f(class: Int): Int }")).parser_class
      end
      assert_equal "Query.f.class can't be a reader, it would replace Object#class", error.message

      error = assert_raises(Schema::Error) do
        Generator.new(TinyGQL.parse_schema("input i { a: Int } type Query { f(i: i): Int }")).parser_class
      end
      assert_equal "i must start with an uppercase letter to be a Ruby class", error.message
    end

    def test_keyword_names
      parser = Generator.new(TinyGQL.parse_schema("input F { in: [Int!], not: F } type Query { f(end: Int, if: F): Int }")).parser_class
      resolvers = Class.new(parser::Resolvers) do
        def Query_f(obj, args, context) = args.end + args.if.in.sum + args.if.not.in.sum
      end.new
      doc = parser.parse("{ f(end: 1, if: { in: [2, 3], not: { in: 4 } }) }")
      assert_equal({ "data" => { "f" => 10 } }, parser.execute(doc, [], resolvers: resolvers))
    end

    def test_resolver_names_must_not_collide
      error = assert_raises(Schema::Error) do
        Generator.new(TinyGQL.parse_schema("type Query { a_b: Int, q: Query_a } type Query_a { b: Int }")).parser_class
      end
      assert_equal "Resolver method Query_a_b for Query_a.b collides with Query.a_b", error.message
    end

    private

    def execute query, variables = {}, resolvers: @resolvers, context: nil
      doc = PARSER.parse(query, scalars: TestScalars.new)
      vars = PARSER.coerce(doc, variables, scalars: TestScalars.new)
      PARSER.execute(doc, vars, resolvers: resolvers, context: context, scalars: TestScalars.new)
    end

    def assert_data data, query, variables = {}, context: nil
      result = execute(query, variables, context: context)
      assert_equal({ "data" => data }, result)
    end
  end
end
