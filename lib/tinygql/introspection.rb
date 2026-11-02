# frozen_string_literal: true

module TinyGQL
  # The introspection types from the GraphQL spec, like __Schema and __Type.
  # Every schema has them, but schema files don't declare them, so
  # TinyGQL.parse_schema adds them
  INTROSPECTION = <<~GRAPHQL
    type __Schema {
      description: String
      types: [__Type!]!
      queryType: __Type!
      mutationType: __Type
      subscriptionType: __Type
      directives: [__Directive!]!
    }

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

    enum __TypeKind {
      SCALAR
      OBJECT
      INTERFACE
      UNION
      ENUM
      INPUT_OBJECT
      LIST
      NON_NULL
    }

    type __Field {
      name: String!
      description: String
      args(includeDeprecated: Boolean = false): [__InputValue!]!
      type: __Type!
      isDeprecated: Boolean!
      deprecationReason: String
    }

    type __InputValue {
      name: String!
      description: String
      type: __Type!
      defaultValue: String
      isDeprecated: Boolean!
      deprecationReason: String
    }

    type __EnumValue {
      name: String!
      description: String
      isDeprecated: Boolean!
      deprecationReason: String
    }

    type __Directive {
      name: String!
      description: String
      locations: [__DirectiveLocation!]!
      args(includeDeprecated: Boolean = false): [__InputValue!]!
      isRepeatable: Boolean!
    }

    enum __DirectiveLocation {
      QUERY
      MUTATION
      SUBSCRIPTION
      FIELD
      FRAGMENT_DEFINITION
      FRAGMENT_SPREAD
      INLINE_FRAGMENT
      VARIABLE_DEFINITION
      SCHEMA
      SCALAR
      OBJECT
      FIELD_DEFINITION
      ARGUMENT_DEFINITION
      INTERFACE
      UNION
      ENUM
      ENUM_VALUE
      INPUT_OBJECT
      INPUT_FIELD_DEFINITION
    }
  GRAPHQL
end
