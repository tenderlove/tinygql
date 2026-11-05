ENV["MT_NO_PLUGINS"] = "1"

require "tinygql/parser"
require "tldr"

module TinyGQL
  class Test < TLDR
    private

    # Ractor.shareable? where there are Ractors, otherwise checks that
    # `value` is frozen all the way down
    def assert_shareable value
      return assert(Ractor.shareable?(value)) if defined?(Ractor)

      seen = {}.compare_by_identity
      check = ->(v) do
        next if Module === v || seen.key?(v)
        seen[v] = true
        assert_predicate v, :frozen?
        case v
        when Array, Struct then v.each(&check)
        when Hash then v.each { |k, x| check.(k); check.(x) }
        end
        v.instance_variables.each { check.(v.instance_variable_get(_1)) }
      end
      check.(value)
    end

    # Generated input objects and arguments as Hashes of their fields, for
    # comparing nested values
    def fields value
      case value
      when Array then value.map { fields _1 }
      when Hash then value.transform_values { fields _1 }
      when Integer, Float, String, Symbol, true, false, nil then value
      else
        if value.class.name&.match?(/::(InputObjects|Arguments)::/) || value.class.name.nil?
          value.instance_variables.to_h { [_1.to_s.delete_prefix("@"), fields(value.instance_variable_get(_1))] }
        else
          value
        end
      end
    end
  end
end
