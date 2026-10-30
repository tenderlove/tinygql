# frozen_string_literal: true

require "helper"

module TinyGQL
  class FrozenTest < Test
    def test_documents_are_frozen
      source = +'query($v: [Int] = [1]) { a(b: "c", d: [1, { e: E }], f: """g""") @h { ...I } } fragment I on J { k }'
      assert_deeply_frozen Parser.parse(source)
      refute_predicate source, :frozen?
    end

    def test_schema_documents_are_frozen
      assert_deeply_frozen Parser.parse(File.read(File.join(__dir__, "schema-kitchen-sink.graphql")))
      assert_deeply_frozen Parser.parse(File.read(File.join(__dir__, "schema-extensions.graphql")))
    end

    private

    def assert_deeply_frozen doc
      doc.each do |node|
        assert_predicate node, :frozen?
        node.instance_variables.each do |ivar|
          assert_predicate node.instance_variable_get(ivar), :frozen?, "#{node.class}##{ivar}"
        end
      end
    end
  end
end
