# frozen_string_literal: true

require "tinygql/parser"

module TinyGQL
  # An index of the types in a schema document, with extensions merged and
  # type references resolved.
  class Schema
    class Error < StandardError; end

    # `kind` is one of :object, :interface, :union, :scalar, :enum, or :input.
    # `fields` maps names to Fields for objects and interfaces, and to
    # InputValues for input objects.  `values` are an enum's value names
    class Type
      attr_reader :kind #: Symbol
      attr_reader :name #: String
      attr_reader :fields #: Hash[String, Field | InputValue]
      attr_reader :interfaces #: Array[String]
      attr_reader :members #: Array[String]
      attr_reader :values #: Array[String]

      #: (Symbol, String, Hash[String, Field | InputValue], Array[String], Array[String], Array[String]) -> void
      def initialize kind, name, fields, interfaces, members, values
        @kind = kind
        @name = name
        @fields = fields
        @interfaces = interfaces
        @members = members
        @values = values
      end

      #: () -> bool
      def composite?; kind == :object || kind == :interface || kind == :union; end

      #: () -> bool
      def input?; kind == :scalar || kind == :enum || kind == :input; end
    end

    # `type` is the field's type node, like `[User!]!`.  `type_name` is the
    # named type with list and non-null wrappers removed
    class Field
      attr_reader :name #: String
      attr_reader :arguments #: Array[InputValue]
      attr_reader :type #: Nodes::NamedType | Nodes::ListType | Nodes::NotNullType

      #: (String, Array[InputValue], Nodes::NamedType | Nodes::ListType | Nodes::NotNullType) -> void
      def initialize name, arguments, type
        @name = name
        @arguments = arguments
        @type = type
      end

      #: () -> String
      def type_name; Schema.named_type(type); end
    end

    # An argument or input object field.  `type` is a type node, and
    # `default_value` is a value node or nil
    class InputValue
      attr_reader :name #: String
      attr_reader :type #: Nodes::NamedType | Nodes::ListType | Nodes::NotNullType
      attr_reader :default_value #: (Nodes::Value | Nodes::ObjectValue | Nodes::Variable)?

      #: (String, Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, (Nodes::Value | Nodes::ObjectValue | Nodes::Variable)?) -> void
      def initialize name, type, default_value
        @name = name
        @type = type
        @default_value = default_value
      end

      #: () -> bool
      def required; type.not_null_type? && default_value.nil?; end
    end

    BUILTIN_SCALARS = %w{ Int Float String Boolean ID }.freeze #: Array[String]

    # The type name with list and non-null wrappers removed
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType) -> String
    def self.named_type type
      type = type.type until type.named_type?
      type.name
    end

    # The type as it's written in GraphQL, like "[User!]!"
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType) -> String
    def self.type_string type
      if type.named_type?
        type.name
      elsif type.list_type?
        "[#{type_string(type.type)}]"
      else
        "#{type_string(type.type)}!"
      end
    end

    #: (String) -> Schema
    def self.parse sdl
      new Parser.parse(sdl)
    end

    # Map of type name to Type, in definition order
    attr_reader :types #: Hash[String, Type]

    # Map of operation type ("query", "mutation", "subscription") to type name
    attr_reader :roots #: Hash[String, String]

    #: (Nodes::Document) -> void
    def initialize document
      @types = {}
      BUILTIN_SCALARS.each { |name| @types[name] = Type.new(:scalar, name, {}, [], [], []) }

      roots = nil
      extensions = []

      document.definitions.each do |defn|
        case defn
        when Nodes::SchemaDefinition
          raise Error, "Multiple schema definitions" if roots
          roots = root_operations(defn.root_operation_definitions)
        when Nodes::ObjectTypeDefinition
          add_type :object, defn.name, fields(defn.fields_definition), names(defn.implements_interfaces)
        when Nodes::InterfaceTypeDefinition
          add_type :interface, defn.name, fields(defn.fields_definition), names(defn.implements_interfaces)
        when Nodes::UnionTypeDefinition
          add_type :union, defn.name, {}, [], names(defn.union_member_types)
        when Nodes::ScalarTypeDefinition
          add_type :scalar, defn.name
        when Nodes::EnumTypeDefinition
          add_type :enum, defn.name, {}, [], [], enum_values(defn.enum_value_definition)
        when Nodes::InputObjectTypeDefinition
          add_type :input, defn.name, input_values(defn.input_fields_definition)
        when Nodes::SchemaExtension,
             Nodes::ObjectTypeExtension,
             Nodes::InterfaceTypeExtension,
             Nodes::UnionTypeExtension,
             Nodes::EnumTypeExtension,
             Nodes::InputObjectTypeExtension
          extensions << defn
        when Nodes::DirectiveDefinition,
             Nodes::ScalarTypeExtension
          # These don't affect which queries can be parsed
        else
          raise Error, "Unexpected #{defn.class.name.split("::").last} in schema"
        end
      end

      roots ||= %w{ query mutation subscription }.each_with_object({}) { |op, h|
        name = op.capitalize
        h[op] = name if @types.key?(name)
      }

      extensions.each do |ext|
        if ext.schema_extension?
          root_operations(ext.root_operation_definitions || []).each do |op, name|
            raise Error, "Schema already has a #{op} type" if roots.key?(op)
            roots[op] = name
          end
        else
          extend_type ext
        end
      end

      @roots = roots
      check_references
    end

    #: (String) -> Type?
    def [] name
      @types[name]
    end

    # Object types that a value of type `name` could be
    #: (String) -> Array[String]
    def possible_types name
      type = @types.fetch(name)
      case type.kind
      when :object then [name]
      when :interface
        @types.each_value.select { |t| t.kind == :object && t.interfaces.include?(name) }.map(&:name)
      when :union then type.members
      else []
      end
    end

    private

    #: (Symbol, String, ?Hash[String, Field | InputValue], ?Array[String], ?Array[String], ?Array[String]) -> void
    def add_type kind, name, fields = {}, interfaces = [], members = [], values = []
      # Schema dumps often declare the built in scalars too
      return if kind == :scalar && BUILTIN_SCALARS.include?(name)
      raise Error, "Duplicate type #{name}" if @types.key?(name)
      @types[name] = Type.new(kind, name, fields, interfaces, members, values)
    end

    #: (Nodes::ObjectTypeExtension | Nodes::InterfaceTypeExtension | Nodes::UnionTypeExtension | Nodes::EnumTypeExtension | Nodes::InputObjectTypeExtension) -> void
    def extend_type ext
      type = @types[ext.name]
      raise Error, "Cannot extend unknown type #{ext.name}" unless type

      expected = case ext
                 when Nodes::ObjectTypeExtension then :object
                 when Nodes::InterfaceTypeExtension then :interface
                 when Nodes::UnionTypeExtension then :union
                 when Nodes::EnumTypeExtension then :enum
                 when Nodes::InputObjectTypeExtension then :input
                 end
      raise Error, "Cannot extend #{type.kind} #{type.name} as #{expected}" unless type.kind == expected

      case expected
      when :union
        type.members.concat names(ext.union_member_types)
      when :enum
        enum_values(ext.enum_value_definition).each do |value|
          raise Error, "Duplicate value #{type.name}.#{value}" if type.values.include?(value)
          type.values << value
        end
      when :input
        input_values(ext.input_fields_definition).each do |name, field|
          raise Error, "Duplicate field #{type.name}.#{name}" if type.fields.key?(name)
          type.fields[name] = field
        end
      else
        fields(ext.fields_definition).each do |name, field|
          raise Error, "Duplicate field #{type.name}.#{name}" if type.fields.key?(name)
          type.fields[name] = field
        end
        type.interfaces.concat names(ext.implements_interfaces)
      end
    end

    #: (Array[Nodes::RootOperationTypeDefinition]) -> Hash[String, String]
    def root_operations defs
      defs.each_with_object({}) { |d, h|
        raise Error, "Duplicate #{d.operation_type} type" if h.key?(d.operation_type)
        h[d.operation_type] = d.named_type.name
      }
    end

    #: (Array[Nodes::FieldDefinition]?) -> Hash[String, Field]
    def fields defs
      (defs || []).each_with_object({}) { |d, h|
        raise Error, "Duplicate field #{d.name}" if h.key?(d.name)
        h[d.name] = Field.new(d.name, input_values(d.arguments_definition).values, d.type)
      }
    end

    #: (Array[Nodes::InputValueDefinition]?) -> Hash[String, InputValue]
    def input_values defs
      (defs || []).each_with_object({}) { |d, h|
        raise Error, "Duplicate input value #{d.name}" if h.key?(d.name)
        h[d.name] = InputValue.new(d.name, d.type, d.default_value)
      }
    end

    #: (Array[Nodes::EnumValueDefinition]?) -> Array[String]
    def enum_values defs
      values = (defs || []).map { |d| d.enum_value.value }
      if (duplicate = values.tally.find { |_, count| count > 1 })
        raise Error, "Duplicate enum value #{duplicate.first}"
      end
      values
    end

    #: (InputValue, String) -> void
    def check_input_type input, where
      name = Schema.named_type(input.type)
      type = @types[name]
      raise Error, "Unknown type #{name} for #{where}" unless type
      raise Error, "#{where} must be an input type, but #{name} is #{type.kind}" unless type.input?
    end

    #: (Array[Nodes::NamedType]?) -> Array[String]
    def names list
      (list || []).map(&:name)
    end

    #: () -> void
    def check_references
      raise Error, "Schema has no query type" unless @roots["query"]

      @roots.each do |op, name|
        type = @types[name]
        raise Error, "Unknown #{op} type #{name}" unless type
        raise Error, "#{op} type #{name} must be an object type" unless type.kind == :object
      end

      @types.each_value do |type|
        if type.kind == :input
          type.fields.each_value { |field| check_input_type field, "#{type.name}.#{field.name}" }
        else
          type.fields.each_value do |field|
            field_type = @types[field.type_name]
            raise Error, "Unknown type #{field.type_name} for #{type.name}.#{field.name}" unless field_type
            if field_type.kind == :input
              raise Error, "#{type.name}.#{field.name} returns input type #{field.type_name}"
            end
            field.arguments.each { |arg| check_input_type arg, "#{type.name}.#{field.name}(#{arg.name})" }
          end
        end

        type.interfaces.each do |name|
          unless @types[name]&.kind == :interface
            raise Error, "#{type.name} implements #{name}, which is not an interface"
          end
        end

        type.members.each do |name|
          unless @types[name]&.kind == :object
            raise Error, "Union #{type.name} includes #{name}, which is not an object type"
          end
        end
      end
    end
  end
end
