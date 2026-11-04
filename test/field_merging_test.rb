require "helper"
require "tinygql/generator"

module TinyGQL
  class FieldMergingTest < Test
    SCHEMA = <<~GRAPHQL
      type Query {
        dog: Dog
        pet: Pet
        pets: [Pet]
        search(q: String, filter: Filter): [SearchResult!]!
      }

      input Filter { tags: [String], near: Int }

      interface Pet { name: String }

      type Dog implements Pet {
        name: String
        nickname: String
        barkVolume: Int
        toys: [Int]!
        doesKnowCommand(command: String): Boolean
        owner: Human
      }

      type Cat implements Pet {
        name: String
        meowVolume: Int
        lives: [Int!]
        owner: Human
      }

      type Human {
        name: String
        age: Int
      }

      union SearchResult = Dog | Cat
    GRAPHQL

    PARSER = Generator.new(TinyGQL.parse_schema(SCHEMA)).parser_class

    def test_mergeable_fields
      [
        "{ dog { name name } }",
        "{ dog { a: name a: name } }",
        "{ dog { doesKnowCommand(command: \"SIT\") doesKnowCommand(command: \"SIT\") } }",
        "query($c: String) { dog { doesKnowCommand(command: $c) doesKnowCommand(command: $c) } }",
        '{ search(q: "x", filter: { tags: ["a"], near: 1 }) { __typename } search(filter: { near: 1, tags: ["a"] }, q: "x") { __typename } }',
        "{ dog { owner { name } owner { age } } }",
        "{ dog { ...A ...B } } fragment A on Dog { name } fragment B on Dog { name }",
        "{ pet { ... on Pet { name } ... on Dog { name } } }",
      ].each do |query|
        assert PARSER.parse(query), query
      end
    end

    def test_different_fields
      assert_error "Fields name conflict because nickname and name are different fields", "{ dog { name: nickname name } }"
    end

    def test_differing_arguments
      assert_error "differing arguments", '{ dog { doesKnowCommand(command: "SIT") doesKnowCommand(command: "HEEL") } }'
      assert_error "differing arguments", '{ dog { doesKnowCommand(command: "SIT") doesKnowCommand } }'
      assert_error "differing arguments", 'query($a: String, $b: String) { dog { doesKnowCommand(command: $a) doesKnowCommand(command: $b) } }'
      assert_error "differing arguments", '{ search(filter: { near: 1 }) { __typename } search(filter: { near: 2 }) { __typename } }'
    end

    def test_conflicts_through_fragments
      assert_error "Fields x conflict", "{ dog { x: name ...F } } fragment F on Dog { x: nickname }"
      assert_error "Fields x conflict", "{ dog { ...F ...G } } fragment F on Dog { x: name } fragment G on Dog { x: nickname }"
      assert_error "Fields x conflict", "{ dog { ... on Dog { x: name } x: barkVolume } }"
    end

    def test_conflicts_in_fragment_definitions
      assert_error "Fields x conflict", "fragment F on Dog { x: name x: nickname } { dog { name } }"
    end

    def test_conflicts_in_merged_subfields
      assert_error "Fields x conflict", "{ dog { owner { x: name } owner { x: age } } }"
      assert_error "Fields x conflict", "{ a: dog { owner { x: name } } a: dog { owner { x: age } } }"
    end

    def test_fields_on_different_object_types_may_differ
      assert PARSER.parse("{ pet { ... on Dog { x: barkVolume } ... on Cat { x: meowVolume } } }")
      assert PARSER.parse("{ pet { ... on Dog { x: nickname } ... on Cat { x: name } } }")
      assert PARSER.parse("{ pet { ... on Dog { x: owner { name } } ... on Cat { x: owner { y: age } } } }")
      # Fields on an interface aren't exclusive with fields on its types
      assert_error "Fields x conflict", "{ pet { x: name ... on Dog { x: nickname } } }"
    end

    def test_exclusive_fields_need_the_same_shape
      assert_error "conflicting types Int and String", "{ pet { ... on Dog { x: barkVolume } ... on Cat { x: name } } }"
      assert_error "conflicting types Int and [Int!]", "{ pet { ... on Dog { x: barkVolume } ... on Cat { x: lives } } }"
      assert_error "conflicting types Int and String", "{ pet { ... on Dog { owner { x: age } } ... on Cat { owner { x: name } } } }"
    end

    def test_return_type_conflicts_can_be_allowed
      parser = Class.new(PARSER) do
        attr_reader :conflicts

        def initialize(...)
          super
          @conflicts = []
        end

        private def return_type_conflict(key, a, type_a, b, type_b)
          @conflicts << [key, a.name, type_string(type_a), b.name, type_string(type_b)]
        end
      end
      query = "{ pet { ... on Dog { x: barkVolume owner { y: name } } ... on Cat { x: lives owner { y: age } } } }"
      instance = parser.new(query)
      assert instance.parse
      assert_equal [["x", "barkVolume", "Int", "lives", "[Int!]"], ["y", "name", "String", "age", "Int"]], instance.conflicts

      # Other conflicts still raise
      error = assert_raises(ValidatingParser::ValidationError) { parser.parse "{ dog { x: name x: nickname } }" }
      assert_includes error.message, "different fields"
    end

    def test_non_null_and_lists_must_match
      assert_error "conflicting types [Int]! and [Int!]", "{ pet { ... on Dog { x: toys } ... on Cat { x: lives } } }"
    end

    def test_repeated_fragments_are_checked_once
      fragments = 12.times.map { |i| "fragment F#{i} on Dog { owner { name } ...F#{i + 1} ...F#{i + 1} }" }
      fragments << "fragment F12 on Dog { name }"
      assert PARSER.parse("{ dog { ...F0 } } #{fragments.join(" ")}")
    end

    private

    def assert_error message, query
      error = assert_raises(ValidatingParser::ValidationError) { PARSER.parse query }
      assert_includes error.message, message
    end
  end
end
