# frozen_string_literal: true

require "helper"

module TinyGQL
  class InspectTest < Test
    def test_inspect
      doc = Parser.parse '{ a(b: [1, $c]) @d }'
      assert_equal <<~EOS, doc.inspect
        @ Document (start: 0)
        └── definitions: (length: 1)
            └── @ OperationDefinition (start: 0)
                ├── type: ∅
                ├── name: ∅
                ├── variable_definitions: ∅
                ├── directives: ∅
                └── selection_set: (length: 1)
                    └── @ Field (start: 2)
                        ├── aliaz: ∅
                        ├── name: "a"
                        ├── arguments: (length: 1)
                        │   └── @ Argument (start: 4)
                        │       ├── name: "b"
                        │       └── value:
                        │           @ ListValue (start: 7)
                        │           └── value: (length: 2)
                        │               ├── @ IntValue (start: 8)
                        │               │   └── value: "1"
                        │               └── @ Variable (start: 11)
                        │                   └── name: "c"
                        ├── directives: (length: 1)
                        │   └── @ Directive (start: 16)
                        │       ├── name: "d"
                        │       └── arguments: ∅
                        ├── selection_set: ∅
                        └── parent_type: ∅
      EOS
    end

    def test_inspect_schema
      doc = Parser.parse 'directive @a repeatable on FIELD'
      assert_equal <<~EOS, doc.definitions.first.inspect
        @ DirectiveDefinition (start: 0)
        ├── description: ∅
        ├── name: "a"
        ├── arguments_definition: ∅
        ├── repeatable: true
        └── directive_locations: (length: 1)
            └── @ ExecutableDirectiveLocation (start: 27)
                └── name: "FIELD"
      EOS
    end
  end
end
