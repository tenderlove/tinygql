# frozen_string_literal: true

require "tinygql/parser"

module TinyGQL
  # An index of the types in a schema document, with extensions merged and
  # type references resolved.
  class Schema
    class Error < StandardError; end

    # `kind` is one of :object, :interface, :union, :scalar, :enum, or :input.
    # `fields` maps names to Fields for objects and interfaces, and to
    # InputValues for input objects.  `values` maps an enum's value names to
    # EnumValues.  `specified_by_url` comes from a scalar's @specifiedBy,
    # `one_of` is whether an input object has @oneOf, and `cost` is the
    # weight from the type's @cost, if it has one
    class Type
      attr_reader :kind #: Symbol
      attr_reader :name #: String
      attr_reader :fields #: Hash[String, Field | InputValue]
      attr_reader :interfaces #: Array[String]
      attr_reader :members #: Array[String]
      attr_reader :values #: Hash[String, EnumValue]
      attr_reader :description #: String?
      attr_reader :specified_by_url #: String?
      attr_reader :one_of #: bool
      attr_reader :cost #: Numeric?

      #: (Symbol, String, Hash[String, Field | InputValue], Array[String], Array[String], Hash[String, EnumValue], ?String?, ?String?, ?bool, ?Numeric?) -> void
      def initialize kind, name, fields, interfaces, members, values, description = nil, specified_by_url = nil, one_of = false, cost = nil
        @kind = kind
        @name = name
        @fields = fields
        @interfaces = interfaces
        @members = members
        @values = values
        @description = description
        @specified_by_url = specified_by_url
        @one_of = one_of
        @cost = cost
      end

      #: () -> bool
      def composite?; kind == :object || kind == :interface || kind == :union; end

      #: () -> bool
      def input?; kind == :scalar || kind == :enum || kind == :input; end
    end

    # `type` is the field's type node, like `[User!]!`.  `type_name` is the
    # named type with list and non-null wrappers removed.
    # `deprecation_reason` is nil unless the field has @deprecated, and
    # `cost` is the weight from the field's @cost, if it has one
    class Field
      attr_reader :name #: String
      attr_reader :arguments #: Array[InputValue]
      attr_reader :type #: Nodes::NamedType | Nodes::ListType | Nodes::NotNullType
      attr_reader :description #: String?
      attr_reader :deprecation_reason #: String?
      attr_reader :cost #: Numeric?

      #: (String, Array[InputValue], Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, ?String?, ?String?, ?Numeric?) -> void
      def initialize name, arguments, type, description = nil, deprecation_reason = nil, cost = nil
        @name = name
        @arguments = arguments
        @type = type
        @description = description
        @deprecation_reason = deprecation_reason
        @cost = cost
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
      attr_reader :description #: String?
      attr_reader :deprecation_reason #: String?

      #: (String, Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, (Nodes::Value | Nodes::ObjectValue | Nodes::Variable)?, ?String?, ?String?) -> void
      def initialize name, type, default_value, description = nil, deprecation_reason = nil
        @name = name
        @type = type
        @default_value = default_value
        @description = description
        @deprecation_reason = deprecation_reason
      end

      #: () -> bool
      def required; type.not_null_type? && default_value.nil?; end
    end

    class EnumValue
      attr_reader :name #: String
      attr_reader :description #: String?
      attr_reader :deprecation_reason #: String?

      #: (String, String?, String?) -> void
      def initialize name, description, deprecation_reason
        @name = name
        @description = description
        @deprecation_reason = deprecation_reason
      end
    end

    # A directive definition.  `locations` are names like "FIELD"
    class Directive
      attr_reader :name #: String
      attr_reader :description #: String?
      attr_reader :arguments #: Array[InputValue]
      attr_reader :locations #: Array[String]
      attr_reader :repeatable #: bool

      #: (String, String?, Array[InputValue], Array[String], bool) -> void
      def initialize name, description, arguments, locations, repeatable
        @name = name
        @description = description
        @arguments = arguments
        @locations = locations
        @repeatable = repeatable
      end
    end

    BUILTIN_SCALARS = %w{ Int Float String Boolean ID }.freeze #: Array[String]

    # Descriptions of the built in scalars, unless the schema declares them
    BUILTIN_SCALAR_DESCRIPTIONS = {
      "Int" => "Represents non-fractional signed whole numeric values. Int can represent values between -(2^31) and 2^31 - 1.",
      "Float" => "Represents signed double-precision fractional values as specified by [IEEE 754](https://en.wikipedia.org/wiki/IEEE_floating_point).",
      "String" => "Represents textual data as UTF-8 character sequences. This type is most often used by GraphQL to represent free-form human-readable text.",
      "Boolean" => "Represents `true` or `false` values.",
      "ID" => "Represents a unique identifier, often used to refetch an object or as key for a cache. The ID type appears in a JSON response as a String; however, it is not intended to be human-readable. When expected as an input type, any string (such as `\"4\"`) or integer (such as `4`) input value will be accepted as an ID.",
    }.freeze #: Hash[String, String]

    # The directives every schema has, from the GraphQL spec.  Schemas may
    # declare them too
    BUILTIN_DIRECTIVES = <<~GRAPHQL #: String
      "Directs the executor to include this field or fragment only when the `if` argument is true."
      directive @include("Included when true." if: Boolean!) on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT

      "Directs the executor to skip this field or fragment when the `if` argument is true."
      directive @skip("Skipped when true." if: Boolean!) on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT

      "Marks an element of a GraphQL schema as no longer supported."
      directive @deprecated(
        "Explains why this element was deprecated, usually also including a suggestion for how to access supported similar data. Formatted using the Markdown syntax, as specified by [CommonMark](https://commonmark.org/)."
        reason: String = "No longer supported"
      ) on FIELD_DEFINITION | ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION | ENUM_VALUE

      "Exposes a URL that specifies the behavior of this scalar."
      directive @specifiedBy("The URL that specifies the behavior of this scalar." url: String!) on SCALAR

      "Indicates exactly one field must be supplied and this field must not be `null`."
      directive @oneOf on INPUT_OBJECT
    GRAPHQL

    DEFAULT_DEPRECATION_REASON = "No longer supported" #: String

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

    # Map of directive name to Directive, including the built in ones
    attr_reader :directives #: Hash[String, Directive]

    # The schema definition's description
    attr_reader :description #: String?

    #: (Nodes::Document) -> void
    def initialize document
      @types = {}
      BUILTIN_SCALARS.each { |name| @types[name] = Type.new(:scalar, name, {}, [], [], {}, BUILTIN_SCALAR_DESCRIPTIONS[name]) }
      @directives = {}
      @description = nil

      roots = nil
      extensions = []

      document.definitions.each do |defn|
        case defn
        when Nodes::SchemaDefinition
          raise Error, "Multiple schema definitions" if roots
          roots = root_operations(defn.root_operation_definitions)
          @description = defn.description&.value
        when Nodes::ObjectTypeDefinition
          add_type :object, defn, fields(defn.fields_definition), names(defn.implements_interfaces)
        when Nodes::InterfaceTypeDefinition
          add_type :interface, defn, fields(defn.fields_definition), names(defn.implements_interfaces)
        when Nodes::UnionTypeDefinition
          add_type :union, defn, {}, [], names(defn.union_member_types)
        when Nodes::ScalarTypeDefinition
          add_type :scalar, defn
        when Nodes::EnumTypeDefinition
          add_type :enum, defn, {}, [], [], enum_values(defn.enum_value_definition)
        when Nodes::InputObjectTypeDefinition
          add_type :input, defn, input_values(defn.input_fields_definition)
        when Nodes::DirectiveDefinition
          add_directive defn
        when Nodes::SchemaExtension,
             Nodes::ObjectTypeExtension,
             Nodes::InterfaceTypeExtension,
             Nodes::UnionTypeExtension,
             Nodes::EnumTypeExtension,
             Nodes::InputObjectTypeExtension
          extensions << defn
        when Nodes::ScalarTypeExtension
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

      Parser.parse(BUILTIN_DIRECTIVES).definitions.each do |defn|
        add_directive defn unless @directives.key?(defn.name)
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

    #: (Symbol, Nodes::ObjectTypeDefinition | Nodes::InterfaceTypeDefinition | Nodes::UnionTypeDefinition | Nodes::ScalarTypeDefinition | Nodes::EnumTypeDefinition | Nodes::InputObjectTypeDefinition, ?Hash[String, Field | InputValue], ?Array[String], ?Array[String], ?Hash[String, EnumValue]) -> void
    def add_type kind, defn, fields = {}, interfaces = [], members = [], values = {}
      name = defn.name
      # Schema dumps often declare the built in scalars too, maybe with
      # their own descriptions
      unless kind == :scalar && BUILTIN_SCALARS.include?(name)
        raise Error, "Duplicate type #{name}" if @types.key?(name)
      end

      specified_by = directive(defn.directives, "specifiedBy")
      url = specified_by && directive_argument(specified_by, "url")
      one_of = !directive(defn.directives, "oneOf").nil?
      description = defn.description&.value || BUILTIN_SCALAR_DESCRIPTIONS[name]
      @types[name] = Type.new(kind, name, fields, interfaces, members, values, description, url, one_of, cost(defn.directives))
    end

    #: (Nodes::DirectiveDefinition) -> void
    def add_directive defn
      raise Error, "Duplicate directive @#{defn.name}" if @directives.key?(defn.name)
      @directives[defn.name] = Directive.new(defn.name, defn.description&.value,
        input_values(defn.arguments_definition).values, defn.directive_locations.map(&:name), defn.repeatable)
    end

    # The first directive called `name` in `directives`
    #: (Array[Nodes::Directive]?, String) -> Nodes::Directive?
    def directive directives, name
      directives&.find { |d| d.name == name }
    end

    # The value of string argument `name` of `directive`, if it was given
    #: (Nodes::Directive, String) -> String?
    def directive_argument directive, name
      arg = directive.arguments&.find { |a| a.name == name }
      arg && !arg.value.null_value? ? arg.value.value : nil
    end

    # The reason given to @deprecated, if `directives` include it
    #: (Array[Nodes::Directive]?) -> String?
    def deprecation_reason directives
      deprecated = directive(directives, "deprecated")
      return unless deprecated
      directive_argument(deprecated, "reason") || DEFAULT_DEPRECATION_REASON
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
        enum_values(ext.enum_value_definition).each do |name, value|
          raise Error, "Duplicate value #{type.name}.#{name}" if type.values.key?(name)
          type.values[name] = value
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
        h[d.name] = Field.new(d.name, input_values(d.arguments_definition).values, d.type,
          d.description&.value, deprecation_reason(d.directives), cost(d.directives))
      }
    end

    # The weight from @cost in `directives`, as in the GraphQL cost
    # directive specification: `@cost(weight: "2.5")`.  The weight is a
    # String holding a number, so it can have a fraction.  Integral weights
    # become Integers
    #: (Array[Nodes::Directive]?) -> Numeric?
    def cost directives
      cost = directive(directives, "cost")
      return unless cost
      weight = directive_argument(cost, "weight")
      raise Error, "@cost needs a weight" unless weight
      value = Float(weight)
      raise Error, "@cost weight must be finite, got #{weight.inspect}" unless value.finite?
      value == value.floor ? value.to_i : value
    rescue ArgumentError
      raise Error, "@cost weight must be a number, got #{weight.inspect}"
    end

    #: (Array[Nodes::InputValueDefinition]?) -> Hash[String, InputValue]
    def input_values defs
      (defs || []).each_with_object({}) { |d, h|
        raise Error, "Duplicate input value #{d.name}" if h.key?(d.name)
        h[d.name] = InputValue.new(d.name, d.type, d.default_value,
          d.description&.value, deprecation_reason(d.directives))
      }
    end

    #: (Array[Nodes::EnumValueDefinition]?) -> Hash[String, EnumValue]
    def enum_values defs
      (defs || []).each_with_object({}) { |d, h|
        name = d.enum_value.value
        raise Error, "Duplicate enum value #{name}" if h.key?(name)
        h[name] = EnumValue.new(name, d.description&.value, deprecation_reason(d.directives))
      }
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

      @directives.each_value do |directive|
        directive.arguments.each { |arg| check_input_type arg, "@#{directive.name}(#{arg.name})" }
      end
    end
  end
end
