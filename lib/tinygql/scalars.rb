# frozen_string_literal: true

module TinyGQL
  # Coerces scalar values, in two steps.  Generated parsers call
  # coerce_literal_X for each literal of scalar type X in a query, like the
  # `1` in `user(id: 1)`, and store the frozen result in the literal's node
  # as `coerced`.  `MyParser.coerce` calls coerce_value_X for each scalar in
  # a request's JSON variables.  Both return the coerced value, or raise
  # InvalidValue.
  #
  # The spec says which literals the built in scalars accept, so parsers
  # check the token and pass only its text, like coerce_literal_Int("1").
  # Literals of custom scalars come with their kind, one of :INT, :FLOAT,
  # :STRING, :BOOLEAN, or :ENUM, like coerce_literal_DateTime(:STRING,
  # "2026-01-01").  String text is already unescaped.  Lists and objects,
  # which a JSON scalar might accept, are passed as :LIST or :OBJECT and the
  # parsed node.  Variables aren't allowed inside those, so the whole
  # literal is known at parse time.  Parsers deeply freeze what custom
  # scalars return with Ractor.make_shareable, so parsed documents can be
  # shared.
  #
  # coerce_value_X gets the decoded JSON value: a String, Integer, Float,
  # true, false, Array, or Hash.  Nulls are handled before it's called.
  #
  # This class implements the built in scalars as the GraphQL spec describes
  # them.  Generated parsers define a subclass, `MyParser::Scalars`, whose
  # methods for the schema's custom scalars raise NotImplementedError.
  # Subclass that to implement them, or to change the built in rules, and
  # pass an instance to `parse` and `coerce`:
  #
  #   class AppScalars < MyParser::Scalars
  #     def coerce_literal_DateTime kind, text
  #       raise InvalidValue, "DateTime must be a string" unless kind == :STRING
  #       coerce_value_DateTime text
  #     end
  #
  #     def coerce_value_DateTime value
  #       raise InvalidValue, "DateTime must be a string" unless value.is_a?(String)
  #       Time.iso8601(value)
  #     rescue ArgumentError
  #       raise InvalidValue, "Invalid DateTime #{value}"
  #     end
  #   end
  #
  #   doc = MyParser.parse query, scalars: AppScalars.new
  #   variables = MyParser.coerce doc, json["variables"], scalars: AppScalars.new
  class Scalars
    class InvalidValue < StandardError
      # Where the invalid value is inside a JSON variable, as input object
      # field names and list indexes
      def path
        @path ||= []
      end
    end

    INT_RANGE = (-2**31)..(2**31 - 1)

    # A short description of a value node for error messages
    def self.describe node
      case node
      when Nodes::StringValue then node.value.dump
      when Nodes::ListValue then "a list"
      when Nodes::ObjectValue then "an input object"
      when Nodes::Variable then "$#{node.name}"
      else node.value
      end
    end

    def coerce_literal_Int text
      value = text.to_i
      unless INT_RANGE.cover?(value)
        raise InvalidValue, "Int cannot represent non 32-bit signed integer value: #{text}"
      end
      value
    end

    def coerce_literal_Float text
      text.to_f
    end

    def coerce_literal_String text
      text
    end

    def coerce_literal_Boolean text
      text == "true"
    end

    def coerce_literal_ID text
      text
    end

    def coerce_value_Int value
      unless value.is_a?(Integer)
        raise InvalidValue, "Int cannot represent non-integer value: #{value.inspect}"
      end
      unless INT_RANGE.cover?(value)
        raise InvalidValue, "Int cannot represent non 32-bit signed integer value: #{value}"
      end
      value
    end

    def coerce_value_Float value
      unless value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)
        raise InvalidValue, "Float cannot represent non numeric value: #{value.inspect}"
      end
      value.to_f
    end

    def coerce_value_String value
      unless value.is_a?(String)
        raise InvalidValue, "String cannot represent a non string value: #{value.inspect}"
      end
      value
    end

    def coerce_value_Boolean value
      unless true == value || false == value
        raise InvalidValue, "Boolean cannot represent a non boolean value: #{value.inspect}"
      end
      value
    end

    def coerce_value_ID value
      if value.is_a?(String)
        value
      elsif value.is_a?(Integer)
        value.to_s
      else
        raise InvalidValue, "ID cannot represent value: #{value.inspect}"
      end
    end
  end
end
