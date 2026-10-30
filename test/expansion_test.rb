require "helper"
require "tinygql"

module TinyGQL
  # Cases are ported from Bluejay's expansion tests so scores stay compatible
  class ExpansionTest < Test
    MAX = 2**64 - 1

    def test_specification_examples
      {
        "{ id }" => 2,
        "{ id id }" => 3,
        "{ a: id b: id }" => 3,
        "{ node { id } }" => 4,
        "{ ... on A { id } ... { name } }" => 7,
        "{ ...Missing }" => 2,
        "query A { id } query B { id }" => 4,
        "{ id } fragment Unused on Query { a b c }" => 6,
        "{ ...F } fragment F on Query { id }" => 6,
        "{ ...F ...F } fragment F on Query { id }" => 9,
        "{ ...F } fragment F on Query { id } fragment F on Query { a b }" => 12,
      }.each { |doc, score| assert_score doc, score }
    end

    def test_conditions_and_values_do_not_change_scores
      assert_score <<~GRAPHQL, 6
        query Q($skip: Boolean! = true) { ...F @skip(if: $skip) }
        fragment F on Impossible { id(arg: 123) @include(if: false) }
      GRAPHQL
      assert_score "{ alias: id(arg: \"long text\") @skip(if: true) }", 2
      assert_score "fragment Unused on Impossible { ...Missing }", 2
    end

    def test_nested_fields
      assert_score "{ node { #{"next { " * 18} name #{"} " * 18} } }", 40
    end

    def test_type_system_definitions_are_ignored
      assert_score "type Query { id: ID } { id }", 2
    end

    def test_empty_document
      score = Expansion.check(Parser.parse(""), 0)
      assert_equal 0, score.value
      refute_predicate score, :cyclic?
    end

    def test_cycles_stop_at_repeated_names_on_each_path
      {
        "{ ...F } fragment F on Query { ...F }" => 6,
        "fragment Unused on Query { ...Unused }" => 2,
        "{ id } fragment F on Query { ...G } fragment G on Query { ...F }" => 10,
        "fragment F on Query { node { ... on Query { ...F } } }" => 6,
        "{ id } fragment F on Query { ...F @skip(if: true) }" => 4,
        "{ ...F } fragment F on Query { id } fragment F on Query { ...F }" => 10,
        "fragment F on Query { ...G } fragment G on Query { id } fragment G on Query { ...F }" => 12,
        "fragment A on Query { ...B } fragment B on Query { ...C } fragment C on Query { ...B }" => 14,
        # Cycle cut scores don't depend on definition order
        "fragment A on Query { ...B } fragment B on Query { ...A id }" => 10,
        "fragment B on Query { ...A id } fragment A on Query { ...B }" => 10,
      }.each do |doc, bound|
        ast = Parser.parse(doc)
        [0, 1, bound - 1].each { |limit| assert_exceeds ast, limit }
        [bound, MAX].each do |limit|
          score = Expansion.check(ast, limit)
          assert_equal bound, score.value, doc
          assert_predicate score, :cyclic?
        end
      end
    end

    def test_shared_dependencies_are_counted_at_each_spread
      assert_score <<~GRAPHQL, 21
        { ...A ...B }
        fragment A on Query { ...C }
        fragment B on Query { ...C }
        fragment C on Query { id }
      GRAPHQL
      assert_score <<~GRAPHQL, 23
        { ...F ...F }
        fragment F on Query { ...G }
        fragment F on Query { id }
        fragment G on Query { id }
      GRAPHQL
    end

    def test_interleaved_duplicate_names_preserve_all_occurrences
      assert_score <<~GRAPHQL, 35
        query A { ...F ...G } query B { ...F }
        fragment F on Query { ...H }
        fragment G on Query { a }
        fragment F on Query { b }
        fragment H on Query { c }
        fragment G on Query { d e }
      GRAPHQL
    end

    def test_duplicate_definition_roots_preserve_cached_group_scores
      assert_score <<~GRAPHQL, 19
        { ...F }
        fragment F on Query { id }
        fragment F on Query { a b }
        fragment G on Query { ...F }
      GRAPHQL
    end

    def test_unused_fragment_expansion_still_enforces_the_limit
      assert_exceeds Parser.parse("{ id } #{doubling_chain(20)}"), 1_000
    end

    def test_exponential_expansion_is_rejected
      assert_exceeds Parser.parse("{ ...F0 } #{doubling_chain(128)}"), MAX
    end

    def test_cycles_do_not_hide_exponential_expansion_elsewhere
      assert_exceeds Parser.parse("{ ...F0 } fragment Cycle on Query { ...Cycle } #{doubling_chain(128)}"), MAX
    end

    def test_large_finite_scores_are_exact
      steps = 60
      assert_score "{ ...F0 } #{doubling_chain(steps)}", 15 * (1 << steps) - 3 * steps - 9
    end

    def test_branching_cycles_do_not_reuse_partial_scores
      doc = 10.times.map { |i|
        "fragment F#{i} on Query { id #{(10.times.to_a - [i]).map { "...F#{_1}" }.join(" ")} }"
      }.join(" ")
      assert_exceeds Parser.parse(doc), 20_000
    end

    # Compare against a direct walk over every graph of three fragments
    def test_cyclic_bounds_match_paths_that_stop_repeated_names
      walk = ->(body, edges, active) {
        score = 2 + edges[body].length
        edges[body].each do |target|
          next if active[target]
          active[target] = true
          score += walk.(target, edges, active)
          active[target] = false
        end
        score
      }

      512.times do |mask|
        edges = 3.times.map { |body| 3.times.select { |target| mask[body * 3 + target] == 1 } }
        doc = edges.each_with_index.map { |targets, body|
          "fragment F#{body} on Query { id #{targets.map { "...F#{_1}" }.join(" ")} }"
        }.join(" ")
        expected = 3.times.sum { |body|
          active = [false] * 3
          active[body] = true
          walk.(body, edges, active)
        }
        ast = Parser.parse(doc)
        assert_equal expected, Expansion.check(ast, MAX).value, doc
        assert_exceeds ast, expected - 1
      end
    end

    def test_duplicate_names_preserve_each_matching_definition_score
      count = 5_000
      assert_score "{ #{"...F " * count} } #{"fragment F on Query { id } " * count}", 1 + 3 * count + 2 * count * count
    end

    def test_long_fragment_chains_do_not_use_the_call_stack
      count = 20_000
      doc = count.times.map { |i| "fragment F#{i} on Query { ...F#{i + 1} }" }.join(" ")
      score = Expansion.check(Parser.parse(doc), MAX)
      assert_equal count * (count + 1), score.value
      refute_predicate score, :cyclic?
    end

    def test_invalid_limits
      ast = Parser.parse("{ id }")
      assert_raises(ArgumentError) { Expansion.check(ast, -1) }
      assert_raises(ArgumentError) { Expansion.check(ast, nil) }
    end

    private

    # Each fragment spreads the next one twice
    def doubling_chain steps
      steps.times.map { |i| "fragment F#{i} on Query { ...F#{i + 1} ...F#{i + 1} }" }.join(" ") +
        " fragment F#{steps} on Query { id }"
    end

    def assert_score doc, expected
      ast = Parser.parse(doc)
      [expected, MAX].each do |limit|
        score = Expansion.check(ast, limit)
        assert_equal expected, score.value, doc
        refute_predicate score, :cyclic?
      end
      assert_exceeds ast, expected - 1
      assert_exceeds ast, 0
    end

    def assert_exceeds ast, limit
      error = assert_raises(Expansion::LimitExceeded) { Expansion.check(ast, limit) }
      assert_equal "Maximum expansion limit of #{limit} exceeded", error.message
    end
  end
end
