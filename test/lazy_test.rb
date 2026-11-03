require "helper"
require "tinygql"
require "tinygql/generator"

module TinyGQL
  class LazyTest < Test
    SCHEMA = <<~GRAPHQL
      type Book {
        id: ID!
        title: String!
        author: Author!
        reviewer: Author
      }

      type Author {
        id: ID!
        name: String!
        books: [Book!]!
      }

      type Query {
        books: [Book]
        requiredBook: Book!
        authors(ids: [ID!]!): [Author]!
      }

      type Mutation {
        rename(id: ID!, name: String!): Author!
      }
    GRAPHQL

    PARSER = Generator.new(TinyGQL.parse_schema(SCHEMA)).parser_class

    Book = Struct.new(:id, :title, :author_id, :reviewer_id)
    Author = Struct.new(:id, :name)

    class DB
      attr_reader :authors, :books, :log

      def initialize
        @authors = { "a1" => Author.new("a1", "Ursula"), "a2" => Author.new("a2", "Mary") }
        @books = [
          Book.new("b1", "Earthsea", "a1", "a2"),
          Book.new("b2", "SPQR", "a2", nil),
          Book.new("b3", "Lathe", "a1", nil),
        ]
        @log = []
      end
    end

    class AuthorLoader < Loader
      def initialize db
        super()
        @db = db
      end

      private

      def perform keys
        @db.log << [:authors, keys]
        keys.each { |key| fulfill key, @db.authors[key] }
      end
    end

    class BooksByAuthorLoader < Loader
      def initialize db
        super()
        @db = db
      end

      private

      def perform keys
        @db.log << [:books, keys]
        keys.each { |key| fulfill key, @db.books.select { _1.author_id == key } }
      end
    end

    Loaders = Struct.new(:authors, :books)

    class Resolvers < PARSER::Resolvers
      def initialize db
        @db = db
      end

      def Query_books(obj, args, context) = @db.books
      def Query_requiredBook(obj, args, context) = @db.books[0]
      def Query_authors(obj, args, context) = context.authors.load_many(args.ids)
      def Book_author(book, args, context) = context.authors.load(book.author_id)
      def Book_reviewer(book, args, context) = book.reviewer_id && context.authors.load(book.reviewer_id)
      def Author_books(author, args, context) = context.books.load(author.id)

      def Mutation_rename obj, args, context
        @db.log << [:rename, args.name]
        @db.authors[args.id].name = args.name
        context.authors.load(args.id)
      end
    end

    def setup
      super
      @db = DB.new
    end

    def test_batches_a_list
      result = execute("{ books { title author { name } } }")
      assert_equal({ "data" => { "books" => [
        { "title" => "Earthsea", "author" => { "name" => "Ursula" } },
        { "title" => "SPQR", "author" => { "name" => "Mary" } },
        { "title" => "Lathe", "author" => { "name" => "Ursula" } },
      ] } }, result)
      # Keys are loaded once
      assert_equal [[:authors, ["a1", "a2"]]], @db.log
    end

    def test_batches_each_depth
      result = execute("{ books { author { books { id author { id } } } reviewer { name } } }")
      assert_equal [{ "id" => "b1", "author" => { "id" => "a1" } }, { "id" => "b3", "author" => { "id" => "a1" } }],
        result.dig("data", "books", 0, "author", "books")
      assert_equal({ "name" => "Mary" }, result.dig("data", "books", 0, "reviewer"))
      assert_nil result.dig("data", "books", 1, "reviewer")
      # Authors already loaded aren't loaded again
      assert_equal [[:authors, ["a1", "a2"]], [:books, ["a1", "a2"]]], @db.log
    end

    def test_lists_of_lazies
      result = execute('{ authors(ids: ["a2", "nope", "a1"]) { name } }')
      assert_equal({ "data" => { "authors" => [{ "name" => "Mary" }, nil, { "name" => "Ursula" }] } }, result)
      assert_equal [[:authors, ["a2", "nope", "a1"]]], @db.log
    end

    def test_null_bubbles_from_lazies
      @db.books[1].author_id = "nope"
      result = execute("{ books { id author { name } } }")
      assert_equal({ "books" => [{ "id" => "b1", "author" => { "name" => "Ursula" } }, nil, { "id" => "b3", "author" => { "name" => "Ursula" } }] }, result["data"])
      assert_equal [{ "message" => "Cannot return null for non-nullable field Book.author", "path" => ["books", 1, "author"] }], result["errors"]
    end

    def test_null_bubbles_from_lazies_through_lists
      resolvers = Class.new(Resolvers) do
        def Book_author(book, args, context) = context.authors.load(book.id == "b3" ? "nope" : book.author_id)
      end.new(@db)
      result = execute('{ authors(ids: ["a1"]) { name books { author { name } } } }', resolvers: resolvers)
      # Author.books is [Book!]!, so the null goes up to the nullable author
      assert_equal({ "authors" => [nil] }, result["data"])
      assert_equal ["authors", 0, "books", 1, "author"], result["errors"][0]["path"]
    end

    def test_null_bubbles_from_lazies_to_data
      @db.books[0].author_id = "nope"
      result = execute("{ books { id } requiredBook { author { name } } }")
      assert_nil result["data"]
      assert_equal [{ "message" => "Cannot return null for non-nullable field Book.author", "path" => ["requiredBook", "author"] }], result["errors"]
    end

    def test_invalid_lazy_values
      resolvers = Class.new(Resolvers) do
        def Book_title(book, args, context) = context.authors.load(book.author_id)
      end.new(@db)
      result = execute("{ books { id title } }", resolvers: resolvers)
      assert_equal({ "books" => [nil, nil, nil] }, result["data"])
      assert_equal ["books", 0, "title"], result["errors"][0]["path"]
      assert_includes result["errors"][0]["message"], "String cannot represent value"
    end

    def test_loader_errors
      loader = Class.new(AuthorLoader) do
        private def perform(keys) = raise(ExecutionError, "authors are down")
      end
      result = execute("{ books { id reviewer { name } } }", loaders: Loaders.new(loader.new(@db), nil))
      assert_equal({ "books" => [{ "id" => "b1", "reviewer" => nil }, { "id" => "b2", "reviewer" => nil }, { "id" => "b3", "reviewer" => nil }] }, result["data"])
      # Each field gets its own error
      assert_equal [{ "message" => "authors are down", "path" => ["books", 0, "reviewer"] }], result["errors"]
    end

    def test_loader_errors_for_each_field
      loader = Class.new(AuthorLoader) do
        private def perform(keys) = raise(ExecutionError, "authors are down")
      end
      result = execute("{ books { id } a: books { reviewer { id } } b: books { reviewer { id } } }", loaders: Loaders.new(loader.new(@db), nil))
      assert_equal [["a", 0, "reviewer"], ["b", 0, "reviewer"]], result["errors"].map { _1["path"] }
    end

    def test_unfulfilled_keys_raise
      loader = Class.new(AuthorLoader) do
        private def perform(keys) = nil
      end
      error = assert_raises(Loader::BrokenError) do
        execute("{ books { author { name } } }", loaders: Loaders.new(loader.new(@db), nil))
      end
      assert_includes error.message, 'didn\'t fulfill key "a1"'
    end

    def test_other_loader_errors_propagate
      loader = Class.new(AuthorLoader) do
        private def perform(keys) = raise(ArgumentError, "bug")
      end
      assert_raises(ArgumentError) do
        execute("{ books { author { name } } }", loaders: Loaders.new(loader.new(@db), nil))
      end
    end

    def test_lazies_of_lazies
      loaders = Loaders.new(AuthorLoader.new(@db), nil)
      outer = Class.new(Loader) do
        define_method(:perform) { |keys| keys.each { fulfill _1, loaders.authors.load(_1) } }
        private :perform
      end.new
      resolvers = Class.new(Resolvers) do
        define_method(:Book_author) { |book, args, context| outer.load(book.author_id) }
      end.new(@db)
      result = execute("{ books { author { name } } }", resolvers: resolvers, loaders: loaders)
      assert_equal ["Ursula", "Mary", "Ursula"], result["data"]["books"].map { _1["author"]["name"] }
      assert_equal [[:authors, ["a1", "a2"]]], @db.log
    end

    def test_mutations_run_in_order
      result = execute('mutation { a: rename(id: "a1", name: "Le Guin") { name } b: rename(id: "a1", name: "U. K. Le Guin") { name } }')
      # Each field's Lazies are done before the next field starts
      assert_equal({ "data" => { "a" => { "name" => "Le Guin" }, "b" => { "name" => "U. K. Le Guin" } } }, result)
      assert_equal [[:rename, "Le Guin"], [:authors, ["a1"]], [:rename, "U. K. Le Guin"]], @db.log
    end

    def test_loaders_cache
      loader = AuthorLoader.new(@db)
      a = loader.load("a1")
      b = loader.load("a1")
      assert_same a.sync, b.sync
      assert_equal "Ursula", loader.load("a1").sync.name
      assert_equal [[:authors, ["a1"]]], @db.log
    end

    private

    def execute query, resolvers: Resolvers.new(@db), loaders: Loaders.new(AuthorLoader.new(@db), BooksByAuthorLoader.new(@db))
      doc = PARSER.parse(query)
      PARSER.execute(doc, PARSER.coerce(doc, {}), resolvers: resolvers, context: loaders)
    end
  end
end
