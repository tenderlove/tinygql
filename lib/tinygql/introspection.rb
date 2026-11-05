# frozen_string_literal: true

module TinyGQL
  # The introspection types from the GraphQL spec, like __Schema and __Type.
  # Every schema has them, but schema files don't declare them, so
  # TinyGQL.parse_schema adds them
  INTROSPECTION = <<~'GRAPHQL' #: String
    "A GraphQL Schema defines the capabilities of a GraphQL server. It exposes all available types and directives on the server, as well as the entry points for query, mutation, and subscription operations."
    type __Schema {
      description: String
      "A list of all types supported by this server."
      types: [__Type!]!
      "The type that query operations will be rooted at."
      queryType: __Type!
      "If this server supports mutation, the type that mutation operations will be rooted at."
      mutationType: __Type
      "If this server support subscription, the type that subscription operations will be rooted at."
      subscriptionType: __Type
      "A list of all directives supported by this server."
      directives: [__Directive!]!
    }

    """
    The fundamental unit of any GraphQL Schema is the type. There are many kinds of types in GraphQL as represented by the `__TypeKind` enum.

    Depending on the kind of a type, certain fields describe information about that type. Scalar types provide no information beyond a name and description, while Enum types provide their values. Object and Interface types provide the fields they describe. Abstract types, Union and Interface, provide the Object types possible at runtime. List and NonNull types compose other types.
    """
    type __Type {
      kind: __TypeKind!
      name: String
      description: String
      fields(includeDeprecated: Boolean = false): [__Field!]
      interfaces: [__Type!]
      possibleTypes: [__Type!]
      enumValues(includeDeprecated: Boolean = false): [__EnumValue!]
      inputFields(includeDeprecated: Boolean = false): [__InputValue!]
      ofType: __Type
      specifiedByURL: String
      isOneOf: Boolean
    }

    "An enum describing what kind of type a given `__Type` is."
    enum __TypeKind {
      "Indicates this type is a scalar."
      SCALAR
      "Indicates this type is an object. `fields` and `interfaces` are valid fields."
      OBJECT
      "Indicates this type is an interface. `fields` and `possibleTypes` are valid fields."
      INTERFACE
      "Indicates this type is a union. `possibleTypes` is a valid field."
      UNION
      "Indicates this type is an enum. `enumValues` is a valid field."
      ENUM
      "Indicates this type is an input object. `inputFields` is a valid field."
      INPUT_OBJECT
      "Indicates this type is a list. `ofType` is a valid field."
      LIST
      "Indicates this type is a non-null. `ofType` is a valid field."
      NON_NULL
    }

    "Object and Interface types are described by a list of Fields, each of which has a name, potentially a list of arguments, and a return type."
    type __Field {
      name: String!
      description: String
      args(includeDeprecated: Boolean = false): [__InputValue!]!
      type: __Type!
      isDeprecated: Boolean!
      deprecationReason: String
    }

    "Arguments provided to Fields or Directives and the input fields of an InputObject are represented as Input Values which describe their type and optionally a default value."
    type __InputValue {
      name: String!
      description: String
      type: __Type!
      "A GraphQL-formatted string representing the default value for this input value."
      defaultValue: String
      isDeprecated: Boolean!
      deprecationReason: String
    }

    "One possible value for a given Enum. Enum values are unique values, not a placeholder for a string or numeric value. However an Enum value is returned in a JSON response as a string."
    type __EnumValue {
      name: String!
      description: String
      isDeprecated: Boolean!
      deprecationReason: String
    }

    """
    A Directive provides a way to describe alternate runtime execution and type validation behavior in a GraphQL document.

    In some cases, you need to provide options to alter GraphQL's execution behavior in ways field arguments will not suffice, such as conditionally including or skipping a field. Directives provide this by describing additional information to the executor.
    """
    type __Directive {
      name: String!
      description: String
      locations: [__DirectiveLocation!]!
      args(includeDeprecated: Boolean = false): [__InputValue!]!
      isRepeatable: Boolean!
    }

    "A Directive can be adjacent to many parts of the GraphQL language, a __DirectiveLocation describes one such possible adjacencies."
    enum __DirectiveLocation {
      "Location adjacent to a query operation."
      QUERY
      "Location adjacent to a mutation operation."
      MUTATION
      "Location adjacent to a subscription operation."
      SUBSCRIPTION
      "Location adjacent to a field."
      FIELD
      "Location adjacent to a fragment definition."
      FRAGMENT_DEFINITION
      "Location adjacent to a fragment spread."
      FRAGMENT_SPREAD
      "Location adjacent to an inline fragment."
      INLINE_FRAGMENT
      "Location adjacent to a variable definition."
      VARIABLE_DEFINITION
      "Location adjacent to a schema definition."
      SCHEMA
      "Location adjacent to a scalar definition."
      SCALAR
      "Location adjacent to an object type definition."
      OBJECT
      "Location adjacent to a field definition."
      FIELD_DEFINITION
      "Location adjacent to an argument definition."
      ARGUMENT_DEFINITION
      "Location adjacent to an interface definition."
      INTERFACE
      "Location adjacent to a union definition."
      UNION
      "Location adjacent to an enum definition."
      ENUM
      "Location adjacent to an enum value definition."
      ENUM_VALUE
      "Location adjacent to an input object type definition."
      INPUT_OBJECT
      "Location adjacent to an input object field definition."
      INPUT_FIELD_DEFINITION
    }
  GRAPHQL
end

module TinyGQL
  # Objects that introspection queries return.  Generated parsers build these
  # for their schema, and the introspection types' default resolvers call the
  # method named after each field.  Lists that take `includeDeprecated` leave
  # out deprecated entries unless it's true.
  module Introspection
    # `list` without its deprecated entries
    #: [T < Field | InputValue | EnumValue] (Array[T]) -> Array[T]
    def self.current list
      return list unless list.any?(&:isDeprecated)
      list.reject(&:isDeprecated).freeze
    end

    class Schema
      attr_reader :description #: String?
      attr_reader :types #: Array[Type]
      attr_reader :queryType #: Type
      attr_reader :mutationType #: Type?
      attr_reader :subscriptionType #: Type?
      attr_reader :directives #: Array[Directive]

      #: (String?, Array[Type], Type, Type?, Type?, Array[Directive]) -> void
      def initialize description, types, query_type, mutation_type, subscription_type, directives
        @description = description
        @types = types.freeze
        @queryType = query_type
        @mutationType = mutation_type
        @subscriptionType = subscription_type
        @directives = directives.freeze
        freeze
      end
    end

    # A named type.  Types refer to each other, so they're created first, and
    # `define` fills in their fields and other lists
    class Type
      attr_reader :kind #: String
      attr_reader :name #: String
      attr_reader :description #: String?
      attr_reader :specifiedByURL #: String?
      attr_reader :isOneOf #: bool?
      attr_reader :interfaces #: Array[Type]?
      attr_reader :possibleTypes #: Array[Type]?

      # @rbs @fields: Array[Field]?
      # @rbs @current_fields: Array[Field]?
      # @rbs @enum_values: Array[EnumValue]?
      # @rbs @current_enum_values: Array[EnumValue]?
      # @rbs @input_fields: Array[InputValue]?
      # @rbs @current_input_fields: Array[InputValue]?

      #: (String, String, String?, String?, bool?) -> void
      def initialize kind, name, description, specified_by_url, one_of
        @kind = kind
        @name = name
        @description = description
        @specifiedByURL = specified_by_url
        @isOneOf = one_of
      end

      # Lists are nil when they don't apply to the type's kind
      #: (Array[Field]?, Array[Type]?, Array[Type]?, Array[EnumValue]?, Array[InputValue]?) -> void
      def define fields, interfaces, possible_types, enum_values, input_fields
        @fields = fields&.freeze
        @current_fields = fields && Introspection.current(fields)
        @interfaces = interfaces&.freeze
        @possibleTypes = possible_types&.freeze
        @enum_values = enum_values&.freeze
        @current_enum_values = enum_values && Introspection.current(enum_values)
        @input_fields = input_fields&.freeze
        @current_input_fields = input_fields && Introspection.current(input_fields)
        freeze
      end

      #: (bool?) -> Array[Field]?
      def fields include_deprecated
        include_deprecated ? @fields : @current_fields
      end

      #: (bool?) -> Array[EnumValue]?
      def enumValues include_deprecated
        include_deprecated ? @enum_values : @current_enum_values
      end

      #: (bool?) -> Array[InputValue]?
      def inputFields include_deprecated
        include_deprecated ? @input_fields : @current_input_fields
      end

      #: () -> nil
      def ofType; end
    end

    # A LIST or NON_NULL type wrapping `ofType`
    class WrappingType
      attr_reader :kind #: String
      attr_reader :ofType #: Type | WrappingType

      #: (String, Type | WrappingType) -> void
      def initialize kind, of_type
        @kind = kind
        @ofType = of_type
        freeze
      end

      #: () -> nil
      def name; end

      #: () -> nil
      def description; end

      #: (bool?) -> nil
      def fields include_deprecated; end

      #: () -> nil
      def interfaces; end

      #: () -> nil
      def possibleTypes; end

      #: (bool?) -> nil
      def enumValues include_deprecated; end

      #: (bool?) -> nil
      def inputFields include_deprecated; end

      #: () -> nil
      def specifiedByURL; end

      #: () -> nil
      def isOneOf; end
    end

    class Field
      attr_reader :name #: String
      attr_reader :description #: String?
      attr_reader :type #: Type | WrappingType
      attr_reader :deprecationReason #: String?

      # @rbs @args: Array[InputValue]
      # @rbs @current_args: Array[InputValue]

      #: (String, String?, Array[InputValue], Type | WrappingType, String?) -> void
      def initialize name, description, args, type, deprecation_reason
        @name = name
        @description = description
        @args = args.freeze
        @current_args = Introspection.current(args)
        @type = type
        @deprecationReason = deprecation_reason
        freeze
      end

      #: (bool?) -> Array[InputValue]
      def args include_deprecated
        include_deprecated ? @args : @current_args
      end

      #: () -> bool
      def isDeprecated; !@deprecationReason.nil?; end
    end

    # An argument or input field.  `defaultValue` is the default printed as
    # GraphQL, like "[1, 2]"
    class InputValue
      attr_reader :name #: String
      attr_reader :description #: String?
      attr_reader :type #: Type | WrappingType
      attr_reader :defaultValue #: String?
      attr_reader :deprecationReason #: String?

      #: (String, String?, Type | WrappingType, String?, String?) -> void
      def initialize name, description, type, default_value, deprecation_reason
        @name = name
        @description = description
        @type = type
        @defaultValue = default_value
        @deprecationReason = deprecation_reason
        freeze
      end

      #: () -> bool
      def isDeprecated; !@deprecationReason.nil?; end
    end

    class EnumValue
      attr_reader :name #: String
      attr_reader :description #: String?
      attr_reader :deprecationReason #: String?

      #: (String, String?, String?) -> void
      def initialize name, description, deprecation_reason
        @name = name
        @description = description
        @deprecationReason = deprecation_reason
        freeze
      end

      #: () -> bool
      def isDeprecated; !@deprecationReason.nil?; end
    end

    class Directive
      attr_reader :name #: String
      attr_reader :description #: String?
      attr_reader :locations #: Array[String]
      attr_reader :isRepeatable #: bool

      # @rbs @args: Array[InputValue]
      # @rbs @current_args: Array[InputValue]

      #: (String, String?, Array[String], Array[InputValue], bool) -> void
      def initialize name, description, locations, args, repeatable
        @name = name
        @description = description
        @locations = locations.freeze
        @args = args.freeze
        @current_args = Introspection.current(args)
        @isRepeatable = repeatable
        freeze
      end

      #: (bool?) -> Array[InputValue]
      def args include_deprecated
        include_deprecated ? @args : @current_args
      end
    end
  end
end
