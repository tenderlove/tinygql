require "helper"
require "tinygql"
require "tinygql/generator"

module TinyGQL
  class IntrospectionTest < Test
    SCHEMA = <<~GRAPHQL
      "The shop's API"
      schema { query: Query mutation: Mutation }

      "A URL"
      scalar URL @specifiedBy(url: "https://example.com/url")

      enum Status {
        "Not published"
        DRAFT
        PUBLISHED
        HIDDEN @deprecated(reason: "Use DRAFT")
      }

      interface Node { id: ID! }

      """
      A blog post
      """
      type Post implements Node {
        id: ID!
        title(upcase: Boolean = false, "Old" lang: String @deprecated): String!
        status: Status
        tags: [String!]
        link: URL @deprecated
      }

      union Result = Post

      input Filter @oneOf {
        "The status"
        status: Status = DRAFT
        tags: [String!] = ["a\\"b", "c"]
        old: Int @deprecated(reason: "Gone")
        nested: Nested = { n: 1, s: null }
      }

      input Nested { n: Int, s: String }

      type Query {
        post(id: ID!): Post
        search(filter: Filter): [Result!]!
      }

      type Mutation { touch: Post }

      "Caches a field"
      directive @cached("Seconds" ttl: Int = 60) repeatable on FIELD | QUERY
    GRAPHQL

    PARSER = Generator.new(TinyGQL.parse_schema(SCHEMA)).parser_class

    def test_type
      data = execute(<<~GRAPHQL)
        {
          __type(name: "Post") {
            kind name description
            fields { name isDeprecated type { kind name ofType { kind name } } }
            interfaces { name }
            possibleTypes { name }
            enumValues { name }
            inputFields { name }
            ofType { name }
          }
        }
      GRAPHQL
      assert_equal({
        "kind" => "OBJECT",
        "name" => "Post",
        "description" => "A blog post",
        "fields" => [
          { "name" => "id", "isDeprecated" => false, "type" => { "kind" => "NON_NULL", "name" => nil, "ofType" => { "kind" => "SCALAR", "name" => "ID" } } },
          { "name" => "title", "isDeprecated" => false, "type" => { "kind" => "NON_NULL", "name" => nil, "ofType" => { "kind" => "SCALAR", "name" => "String" } } },
          { "name" => "status", "isDeprecated" => false, "type" => { "kind" => "ENUM", "name" => "Status", "ofType" => nil } },
          { "name" => "tags", "isDeprecated" => false, "type" => { "kind" => "LIST", "name" => nil, "ofType" => { "kind" => "NON_NULL", "name" => nil } } },
        ],
        "interfaces" => [{ "name" => "Node" }],
        "possibleTypes" => nil,
        "enumValues" => nil,
        "inputFields" => nil,
        "ofType" => nil,
      }, data["__type"])
    end

    def test_unknown_type
      assert_nil execute('{ __type(name: "Nope") { name } }')["__type"]
    end

    def test_deprecated_entries
      data = execute(<<~GRAPHQL)
        {
          post: __type(name: "Post") {
            fields(includeDeprecated: true) { name isDeprecated deprecationReason }
            title: fields { name args { name } all: args(includeDeprecated: true) { name description deprecationReason } }
          }
          status: __type(name: "Status") {
            current: enumValues { name description }
            all: enumValues(includeDeprecated: true) { name deprecationReason }
          }
          filter: __type(name: "Filter") {
            current: inputFields { name }
            all: inputFields(includeDeprecated: true) { name isDeprecated deprecationReason }
          }
        }
      GRAPHQL
      assert_equal ["id", "title", "status", "tags", "link"], data["post"]["fields"].map { _1["name"] }
      assert_equal({ "name" => "link", "isDeprecated" => true, "deprecationReason" => "No longer supported" }, data["post"]["fields"].last)
      title = data["post"]["title"].find { _1["name"] == "title" }
      assert_equal [{ "name" => "upcase" }], title["args"]
      assert_equal [{ "name" => "upcase", "description" => nil, "deprecationReason" => nil },
                    { "name" => "lang", "description" => "Old", "deprecationReason" => "No longer supported" }], title["all"]

      assert_equal [{ "name" => "DRAFT", "description" => "Not published" }, { "name" => "PUBLISHED", "description" => nil }], data["status"]["current"]
      assert_equal({ "name" => "HIDDEN", "deprecationReason" => "Use DRAFT" }, data["status"]["all"].last)

      assert_equal ["status", "tags", "nested"], data["filter"]["current"].map { _1["name"] }
      assert_equal({ "name" => "old", "isDeprecated" => true, "deprecationReason" => "Gone" }, data["filter"]["all"][2])
    end

    def test_input_objects_and_scalars
      data = execute(<<~GRAPHQL)
        {
          filter: __type(name: "Filter") { kind isOneOf specifiedByURL inputFields { name description defaultValue } }
          nested: __type(name: "Nested") { isOneOf }
          url: __type(name: "URL") { kind description specifiedByURL isOneOf }
          int: __type(name: "Int") { description specifiedByURL }
          result: __type(name: "Result") { kind possibleTypes { name } fields { name } }
          node: __type(name: "Node") { kind possibleTypes { name } fields { name } }
        }
      GRAPHQL
      assert_equal({
        "kind" => "INPUT_OBJECT",
        "isOneOf" => true,
        "specifiedByURL" => nil,
        "inputFields" => [
          { "name" => "status", "description" => "The status", "defaultValue" => "DRAFT" },
          { "name" => "tags", "description" => nil, "defaultValue" => '["a\\"b", "c"]' },
          { "name" => "nested", "description" => nil, "defaultValue" => "{n: 1, s: null}" },
        ],
      }, data["filter"])
      assert_equal({ "isOneOf" => false }, data["nested"])
      assert_equal({ "kind" => "SCALAR", "description" => "A URL", "specifiedByURL" => "https://example.com/url", "isOneOf" => nil }, data["url"])
      assert_equal Schema::BUILTIN_SCALAR_DESCRIPTIONS["Int"], data["int"]["description"]
      assert_equal({ "kind" => "UNION", "possibleTypes" => [{ "name" => "Post" }], "fields" => nil }, data["result"])
      assert_equal({ "kind" => "INTERFACE", "possibleTypes" => [{ "name" => "Post" }], "fields" => [{ "name" => "id" }] }, data["node"])
    end

    def test_schema
      data = execute(<<~GRAPHQL)
        {
          __schema {
            description
            queryType { name } mutationType { name } subscriptionType { name }
            types { name }
            directives { name description locations isRepeatable args { name description defaultValue type { name } } }
          }
        }
      GRAPHQL
      schema = data["__schema"]
      assert_equal "The shop's API", schema["description"]
      assert_equal({ "name" => "Query" }, schema["queryType"])
      assert_equal({ "name" => "Mutation" }, schema["mutationType"])
      assert_nil schema["subscriptionType"]
      names = schema["types"].map { _1["name"] }
      assert_equal names.uniq, names
      assert_includes names, "__Type"
      assert_includes names, "Boolean"
      assert_includes names, "Nested"

      assert_equal ["cached", "include", "skip", "deprecated", "specifiedBy", "oneOf"], schema["directives"].map { _1["name"] }
      assert_equal({
        "name" => "cached",
        "description" => "Caches a field",
        "locations" => ["FIELD", "QUERY"],
        "isRepeatable" => true,
        "args" => [{ "name" => "ttl", "description" => "Seconds", "defaultValue" => "60", "type" => { "name" => "Int" } }],
      }, schema["directives"][0])
      deprecated = schema["directives"].find { _1["name"] == "deprecated" }
      assert_equal '"No longer supported"', deprecated["args"][0]["defaultValue"]
    end

    def test_introspection_types_describe_themselves
      data = execute('{ __type(name: "__TypeKind") { kind description enumValues { name } } }')
      assert_equal "ENUM", data["__type"]["kind"]
      assert_includes data["__type"]["description"], "__Type"
      assert_equal %w{ SCALAR OBJECT INTERFACE UNION ENUM INPUT_OBJECT LIST NON_NULL }, data["__type"]["enumValues"].map { _1["name"] }
    end

    def test_full_introspection_query
      result = run_query(INTROSPECTION_QUERY)
      assert_nil result["errors"]
      types = result["data"]["__schema"]["types"]
      assert_equal PARSER::Introspection::TYPES.keys, types.map { _1["name"] }
    end

    def test_resolvers_can_turn_off_introspection
      resolvers = Class.new(PARSER::Resolvers) do
        def Query___schema obj, args, context
          raise ExecutionError, "Introspection is off"
        end

        def Query___type obj, args, context
          nil
        end
      end
      result = run_query('{ __type(name: "Post") { name } __typename }', resolvers.new)
      assert_equal({ "__type" => nil, "__typename" => "Query" }, result["data"])
      result = run_query("{ __schema { queryType { name } } }", resolvers.new)
      assert_nil result["data"]
      assert_equal [{ "message" => "Introspection is off", "path" => ["__schema"] }], result["errors"]
    end

    def test_introspection_data_is_shareable
      assert_shareable PARSER::Introspection::SCHEMA
    end

    INTROSPECTION_QUERY = <<~GRAPHQL
      query IntrospectionQuery {
        __schema {
          description
          queryType { name } mutationType { name } subscriptionType { name }
          types { ...FullType }
          directives { name description isRepeatable locations args(includeDeprecated: true) { ...InputValue } }
        }
      }
      fragment FullType on __Type {
        kind name description specifiedByURL isOneOf
        fields(includeDeprecated: true) {
          name description
          args(includeDeprecated: true) { ...InputValue }
          type { ...TypeRef }
          isDeprecated deprecationReason
        }
        inputFields(includeDeprecated: true) { ...InputValue }
        interfaces { ...TypeRef }
        enumValues(includeDeprecated: true) { name description isDeprecated deprecationReason }
        possibleTypes { ...TypeRef }
      }
      fragment InputValue on __InputValue {
        name description type { ...TypeRef } defaultValue isDeprecated deprecationReason
      }
      fragment TypeRef on __Type {
        kind name
        ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } }
      }
    GRAPHQL

    private

    def run_query query, resolvers = PARSER::Resolvers.new
      doc = PARSER.parse(query)
      PARSER.execute(doc, PARSER.coerce(doc, {}), resolvers: resolvers, context: nil)
    end

    def execute query
      result = run_query(query)
      assert_nil result["errors"]
      result["data"]
    end
  end
end
