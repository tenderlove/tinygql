# frozen_string_literal: true

require "tinygql/executable_parser"

module TinyGQL
  # Parses any GraphQL document, including schemas
  class Parser < ExecutableParser
    private

    def definition
      case token_name
      when :FRAGMENT, :QUERY, :MUTATION, :SUBSCRIPTION, :LCURLY
        executable_definition
      when :EXTEND
        type_system_extension
      else
        desc = if at?(:STRING); string_value; end

        type_system_definition desc
      end
    end

    def type_system_extension
      expect_token :EXTEND
      case token_name
      when :SCHEMA then schema_extension
      when :SCALAR then scalar_type_extension
      when :TYPE then object_type_extension
      when :INTERFACE then interface_type_extension
      when :UNION then union_type_extension
      when :ENUM then enum_type_extension
      when :INPUT then input_object_type_extension
      else
        expect_token :SCALAR
      end
    end

    def schema_extension
      loc = pos
      expect_token :SCHEMA
      directives = if at?(:DIR_SIGN); self.directives; end
      defs = if at?(:LCURLY)
        expect_token :LCURLY
        list = root_operation_type_definition
        expect_token :RCURLY
        list
      end
      Nodes::SchemaExtension.new(loc, directives, defs)
    end

    def input_object_type_extension
      loc = pos
      expect_token :INPUT
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      input_fields_definition = if at?(:LCURLY); self.input_fields_definition; end
      Nodes::InputObjectTypeExtension.new(loc, name, directives, input_fields_definition)
    end

    def enum_type_extension
      loc = pos
      expect_token :ENUM
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      enum_values_definition = if at?(:LCURLY); self.enum_values_definition; end
      Nodes::EnumTypeExtension.new(loc, name, directives, enum_values_definition)
    end

    def union_type_extension
      loc = pos
      expect_token :UNION
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      union_member_types = if at?(:EQUALS); self.union_member_types; end
      Nodes::UnionTypeExtension.new(loc, name, directives, union_member_types)
    end

    def interface_type_extension
      loc = pos
      expect_token :INTERFACE
      name = self.name
      implements_interfaces = if at?(:IMPLEMENTS); self.implements_interfaces; end
      directives           = if at?(:DIR_SIGN); self.directives; end
      fields_definition   = if at?(:LCURLY); self.fields_definition; end
      Nodes::InterfaceTypeExtension.new(loc, name, implements_interfaces, directives, fields_definition)
    end

    def scalar_type_extension
      loc = pos
      expect_token :SCALAR
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      Nodes::ScalarTypeExtension.new(loc, name, directives)
    end

    def object_type_extension
      loc = pos
      expect_token :TYPE
      name = self.name
      implements_interfaces = if at?(:IMPLEMENTS); self.implements_interfaces; end
      directives           = if at?(:DIR_SIGN); self.directives; end
      fields_definition   = if at?(:LCURLY); self.fields_definition; end
      Nodes::ObjectTypeExtension.new(loc, name, implements_interfaces, directives, fields_definition)
    end

    def type_system_definition desc
      case token_name
      when :SCHEMA then schema_definition(desc)
      when :DIRECTIVE then directive_defintion(desc)
      else
        type_definition(desc)
      end
    end

    def directive_defintion desc
      loc = pos
      expect_token :DIRECTIVE
      expect_token :DIR_SIGN
      name = self.name
      arguments_definition = if at?(:LPAREN); self.arguments_definition; end
      repeatable = if at?(:REPEATABLE)
        accept_token
        true
      else
        false
      end
      expect_token :ON
      directive_locations = self.directive_locations
      Nodes::DirectiveDefinition.new(loc, desc, name, arguments_definition, repeatable, directive_locations)
    end

    def directive_locations
      accept_token if at?(:PIPE)
      list = [directive_location]
      while at?(:PIPE)
        accept_token
        list << directive_location
      end
      list.freeze
    end

    def directive_location
      loc = pos
      directive = expect_token_value :IDENTIFIER

      case directive
      when "QUERY", "MUTATION", "SUBSCRIPTION", "FIELD", "FRAGMENT_DEFINITION", "FRAGMENT_SPREAD", "INLINE_FRAGMENT", "VARIABLE_DEFINITION"
        Nodes::ExecutableDirectiveLocation.new(loc, directive)
      when "SCHEMA",
        "SCALAR",
        "OBJECT",
        "FIELD_DEFINITION",
        "ARGUMENT_DEFINITION",
        "INTERFACE",
        "UNION",
        "ENUM",
        "ENUM_VALUE",
        "INPUT_OBJECT",
        "INPUT_FIELD_DEFINITION"
        Nodes::TypeSystemDirectiveLocation.new(loc, directive)
      else
        raise UnexpectedToken, "Expected directive #{directive}"
      end
    end

    def type_definition desc
      case token_name
      when :TYPE then object_type_definition(desc)
      when :INTERFACE then interface_type_definition(desc)
      when :UNION then union_type_definition(desc)
      when :SCALAR then scalar_type_definition(desc)
      when :ENUM then enum_type_definition(desc)
      when :INPUT then input_object_type_definition(desc)
      else
        expect_token :TYPE
      end
    end

    def input_object_type_definition desc
      loc = pos
      expect_token :INPUT
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      input_fields_definition = if at?(:LCURLY); self.input_fields_definition; end
      Nodes::InputObjectTypeDefinition.new(loc, desc, name, directives, input_fields_definition)
    end

    def input_fields_definition
      expect_token :LCURLY
      list = []
      while !at?(:RCURLY)
        list << input_value_definition
      end
      expect_token :RCURLY
      list.freeze
    end

    def enum_type_definition desc
      loc = pos
      expect_token :ENUM
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      enum_values_definition = if at?(:LCURLY); self.enum_values_definition; end
      Nodes::EnumTypeDefinition.new(loc, desc, name, directives, enum_values_definition)
    end

    def enum_values_definition
      expect_token :LCURLY
      list = []
      while !at?(:RCURLY)
        list << enum_value_definition
      end
      expect_token :RCURLY
      list.freeze
    end

    def enum_value_definition
      loc = pos
      description = if at?(:STRING); string_value; end
      enum_value = self.enum_value
      directives = if at?(:DIR_SIGN); self.directives; end
      Nodes::EnumValueDefinition.new(loc, description, enum_value, directives)
    end

    def scalar_type_definition desc
      loc = pos
      expect_token :SCALAR
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      Nodes::ScalarTypeDefinition.new(loc, desc, name, directives)
    end

    def union_type_definition desc
      loc = pos
      expect_token :UNION
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      union_member_types = if at?(:EQUALS); self.union_member_types; end
      Nodes::UnionTypeDefinition.new(loc, desc, name, directives, union_member_types)
    end

    def union_member_types
      expect_token :EQUALS
      accept_token if at?(:PIPE)
      list = [named_type]
      while at?(:PIPE)
        accept_token
        list << named_type
      end
      list.freeze
    end

    def interface_type_definition desc
      loc = pos
      expect_token :INTERFACE
      name = self.name
      implements_interfaces = if at?(:IMPLEMENTS); self.implements_interfaces; end
      directives           = if at?(:DIR_SIGN); self.directives; end
      fields_definition   = if at?(:LCURLY); self.fields_definition; end
      Nodes::InterfaceTypeDefinition.new(loc, desc, name, implements_interfaces, directives, fields_definition)
    end

    def object_type_definition desc
      loc = pos
      expect_token :TYPE
      name = self.name
      implements_interfaces = if at?(:IMPLEMENTS); self.implements_interfaces; end
      directives           = if at?(:DIR_SIGN); self.directives; end
      fields_definition   = if at?(:LCURLY); self.fields_definition; end

      Nodes::ObjectTypeDefinition.new(loc, desc, name, implements_interfaces, directives, fields_definition)
    end

    def fields_definition
      expect_token :LCURLY
      list = []
      while !at?(:RCURLY)
        list << field_definition
      end
      expect_token :RCURLY
      list.freeze
    end

    def field_definition
      loc = pos
      description = if at?(:STRING); string_value; end
      name = self.name
      arguments_definition = if at?(:LPAREN); self.arguments_definition; end
      expect_token :COLON
      type = self.type
      directives           = if at?(:DIR_SIGN); self.directives; end

      Nodes::FieldDefinition.new(loc, description, name, arguments_definition, type, directives)
    end

    def arguments_definition
      expect_token :LPAREN
      list = []
      while !at?(:RPAREN)
        list << input_value_definition
      end
      expect_token :RPAREN
      list.freeze
    end

    def input_value_definition
      loc = pos
      description = if at?(:STRING); string_value; end
      name = self.name
      expect_token :COLON
      type = self.type
      default_value = if at?(:EQUALS); self.default_value; end
      directives           = if at?(:DIR_SIGN); self.directives; end
      Nodes::InputValueDefinition.new(loc, description, name, type, default_value, directives)
    end

    def implements_interfaces
      expect_token :IMPLEMENTS
      accept_token if at?(:AMP)
      list = [self.named_type]
      while true
        if at?(:AMP)
          accept_token
        elsif !at?(:IDENTIFIER)
          # Legacy SDL allows interfaces without `&` separators. Keywords
          # aren't accepted here so we don't consume the next definition.
          break
        end
        list << self.named_type
      end
      list.freeze
    end

    def schema_definition desc
      loc = pos
      expect_token :SCHEMA

      directives = if at?(:DIR_SIGN); self.directives; end
      expect_token :LCURLY
      defs = root_operation_type_definition
      expect_token :RCURLY
      Nodes::SchemaDefinition.new(loc, desc, directives, defs)
    end

    def root_operation_type_definition
      list = []
      while !at?(:RCURLY)
        loc = pos
        operation_type = self.operation_type
        expect_token :COLON
        list << Nodes::RootOperationTypeDefinition.new(loc, operation_type, named_type)
      end
      list.freeze
    end
  end
end
