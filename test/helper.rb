ENV["MT_NO_PLUGINS"] = "1"

require "tinygql/parser"
require "tldr"

module TinyGQL
  class Test < TLDR
    private

    # Generated input objects as Hashes of their fields, for
    # comparing nested values
    def fields value
      case value
      when Array then value.map { fields _1 }
      when Hash then value.transform_values { fields _1 }
      when Integer, Float, String, Symbol, true, false, nil then value
      else
        if value.class.name&.match?(/::InputObjects::/) || value.class.name.nil?
          value.instance_variables.to_h { [_1.to_s.delete_prefix("@"), fields(value.instance_variable_get(_1))] }
        else
          value
        end
      end
    end
  end
end
