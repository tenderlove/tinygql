# frozen_string_literal: true

require "tinygql/scalars"

module TinyGQL
  # Coerces input values: the JSON variables of a request, and literals in
  # parsed documents.  Generated parsers define a subclass, `MyParser::Inputs`,
  # with a method for each of the schema's input types.  Use it through
  # `MyParser.coerce`.
  #
  # Values become Ruby values.  Scalars are coerced with the Scalars
  # methods, enums become their names, input objects become instances of
  # the generated classes in `MyParser::InputObjects`, which are frozen and
  # have a reader for each field, and lists become frozen Arrays.  A single
  # value where a list is expected becomes a list of one.  Input object
  # fields that are missing get their default, or nil when they don't have
  # one.
  class Inputs
    # @rbs @scalars: Scalars

    # Variables or operation names in a request that don't fit the document
    class Error < StandardError; end

    # Stands in for a variable that wasn't provided and has no default.  A
    # missing variable isn't the same as null: an argument whose variable
    # is missing gets the argument's default
    class Undefined
      #: () -> String
      def inspect
        "UNDEFINED"
      end
    end
    UNDEFINED = Undefined.new.freeze #: Undefined

    EMPTY = [].freeze #: Array[untyped]

    #: (Scalars) -> void
    def initialize scalars
      @scalars = scalars
    end

    # Coerces the JSON `variables` of a request for operation `op` in
    # `doc`, a document parsed by the same generated parser.  Returns a
    # frozen Array of values indexed by Variable#index, holding UNDEFINED
    # for variables that weren't provided
    #: (Nodes::Document, untyped, String?) -> Array[untyped]
    def coerce doc, variables, op
      definitions = operation(doc, op).variable_definitions
      return EMPTY unless definitions

      variables ||= {}
      raise Error, "Variables must be an object" unless variables.is_a?(Hash)

      values = []
      i = 0
      while i < definitions.length
        definition = definitions[i]
        var = definition.variable
        type = definition.type
        name = var.name

        values[var.index] = if variables.key?(name)
          value = variables[name]
          if value.nil?
            if type.not_null_type?
              raise Error, "Variable $#{name} of non-null type #{type_string(type)} must not be null"
            end
            nil
          else
            begin
              coerce_value type, value
            rescue Scalars::InvalidValue => e
              raise Error, "Invalid value for variable $#{name}#{path_string(e.path)}: #{e.message}"
            end
          end
        elsif (default = definition.default_value)
          literal_value type, default, EMPTY
        elsif type.not_null_type?
          raise Error, "Variable $#{name} of required type #{type_string(type)} was not provided"
        else
          UNDEFINED
        end
        i += 1
      end
      values.freeze
    end

    # Coerces a JSON value of `type`, a type node
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, untyped) -> untyped
    def coerce_value type, value
      if type.not_null_type?
        raise Scalars::InvalidValue, "Expected non-nullable type #{type_string(type)} not to be null" if value.nil?
        coerce_value type.type, value
      elsif value.nil?
        nil
      elsif type.list_type?
        if value.is_a?(Array)
          coerce_list type.type, value
        else
          [coerce_value(type.type, value)].freeze
        end
      else
        coerce_named type.name, value
      end
    end

    # Converts a value node of `type` from a parsed document to a Ruby
    # value.  Variables are looked up in `variables`, from `coerce`
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Nodes::Value | Nodes::ObjectValue | Nodes::Variable, Array[untyped]) -> untyped
    def literal_value type, node, variables
      if node.variable?
        variables[node.index]
      elsif node.null_value?
        nil
      elsif type.not_null_type?
        literal_value type.type, node, variables
      elsif type.list_type?
        if node.list_value?
          literal_list type.type, node.value, variables
        else
          [literal_item(type.type, node, variables)].freeze
        end
      else
        literal_named type.name, node, variables
      end
    end

    # Finds the operation a request runs.  Parsed documents have unique
    # operation names, and only one operation if it's anonymous
    #: (Nodes::Document, String?) -> Nodes::OperationDefinition
    def operation doc, op
      definitions = doc.definitions
      found = nil
      i = 0
      while i < definitions.length
        definition = definitions[i]
        if definition.operation_definition?
          if op.nil?
            raise Error, "An operation name is required when the document has more than one operation" if found
            found = definition
          elsif definition.name == op
            return definition
          end
        end
        i += 1
      end
      raise Error, "Unknown operation #{op}" if op || found.nil?
      found
    end

    private

    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Array[untyped]) -> Array[untyped]
    def coerce_list type, values
      list = Array.new(values.length)
      i = 0
      while i < values.length
        list[i] = coerce_value(type, values[i])
        i += 1
      end
      list.freeze
    rescue Scalars::InvalidValue => e
      e.path.unshift i
      raise
    end

    # Coerces the JSON value of input object field `key`
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, untyped, String) -> untyped
    def coerce_field type, value, key
      coerce_value type, value
    rescue Scalars::InvalidValue => e
      e.path.unshift key
      raise
    end

    #: (Hash[String, true], String, untyped) -> String
    def coerce_enum values, type, value
      unless value.is_a?(String)
        raise Scalars::InvalidValue, "Enum #{type} cannot represent non-string value: #{value.inspect}"
      end
      unless values.key?(value)
        raise Scalars::InvalidValue, "Value #{value} does not exist in #{type} enum"
      end
      value
    end

    #: (String, untyped) -> void
    def input_object! type, value
      unless value.is_a?(Hash)
        raise Scalars::InvalidValue, "Expected type #{type} to be an object, found #{value.inspect}"
      end
    end

    #: (String, String) -> bot
    def unknown_input_field! name, type
      raise Scalars::InvalidValue, "Field #{name} is not defined by type #{type}"
    end

    #: (String, String, String) -> bot
    def missing_input_field! name, type, field_type
      raise Scalars::InvalidValue, "Field #{type}.#{name} of required type #{field_type} was not provided"
    end

    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Array[Nodes::Value | Nodes::ObjectValue | Nodes::Variable], Array[untyped]) -> Array[untyped]
    def literal_list type, nodes, variables
      list = Array.new(nodes.length)
      i = 0
      while i < nodes.length
        list[i] = literal_item(type, nodes[i], variables)
        i += 1
      end
      list.freeze
    end

    # A list item.  Missing variables in lists are null
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Nodes::Value | Nodes::ObjectValue | Nodes::Variable, Array[untyped]) -> untyped
    def literal_item type, node, variables
      value = literal_value(type, node, variables)
      value = nil if UNDEFINED.equal?(value)
      if value.nil? && type.not_null_type?
        raise Scalars::InvalidValue, "Expected non-nullable type #{type_string(type)} not to be null"
      end
      value
    end

    # An input object field's value, or UNDEFINED if it's a missing variable
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Nodes::Value | Nodes::ObjectValue | Nodes::Variable, Array[untyped]) -> untyped
    def literal_field type, node, variables
      value = literal_value(type, node, variables)
      if value.nil? && type.not_null_type?
        raise Scalars::InvalidValue, "Expected non-nullable type #{type_string(type)} not to be null"
      end
      value
    end

    #: (Array[String | Integer]) -> String
    def path_string path
      str = +""
      i = 0
      while i < path.length
        key = path[i]
        if key.is_a?(Integer)
          str << "[" << key.to_s << "]"
        else
          str << "." << key
        end
        i += 1
      end
      str
    end

    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType) -> String
    def type_string type
      if type.list_type?
        "[#{type_string(type.type)}]"
      elsif type.not_null_type?
        "#{type_string(type.type)}!"
      else
        type.name
      end
    end
  end
end
