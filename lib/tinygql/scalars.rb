# frozen_string_literal: true

module TinyGQL
  # Coerces scalar values.  Generated parsers call coerce_literal_X for each
  # literal of scalar type X in a query, like the `1` in `user(id: 1)`, and
  # store the frozen result in the literal's node as `coerced`.  The method
  # returns the coerced value, or raises InvalidValue.
  #
  # The spec says which literals the built in scalars accept, so parsers
  # check the token and pass only its text, like coerce_literal_Int("1").
  # Custom scalars get the kind of literal too, one of :INT, :FLOAT,
  # :STRING, :BOOLEAN, or :ENUM, like coerce_literal_DateTime(:STRING,
  # "2026-01-01").  String text is already unescaped.  Lists and objects,
  # which a JSON scalar might accept, are passed as :LIST or :OBJECT and the
  # parsed node.  Variables aren't allowed inside those, so the whole
  # literal is known at parse time.  Parsers deeply freeze what custom
  # scalars return with Ractor.make_shareable, so parsed documents can be
  # shared.
  #
  # This class implements the built in scalars as the GraphQL spec describes
  # them.  Generated parsers define a subclass, `MyParser::Scalars`, whose
  # methods for the schema's custom scalars raise NotImplementedError.
  # Subclass that to implement them, or to change the built in rules, and
  # pass an instance to `parse`:
  #
  #   class AppScalars < MyParser::Scalars
  #     def coerce_literal_DateTime kind, text
  #       raise InvalidValue, "DateTime must be a string" unless kind == :STRING
  #       Time.iso8601(text)
  #     rescue ArgumentError
  #       raise InvalidValue, "Invalid DateTime #{text}"
  #     end
  #   end
  #
  #   MyParser.parse query, scalars: AppScalars.new
  class Scalars
    class InvalidValue < StandardError; end

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
  end
end
