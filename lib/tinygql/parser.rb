# frozen_string_literal: true

require "tinygql/lexer"
require "tinygql/nodes"

module TinyGQL
  class Parser
    class UnexpectedToken < StandardError; end

    def self.parse doc
      new(doc).parse
    end

    def initialize doc
      @lexer = Lexer.new doc
      @token_name = @lexer.advance
    end

    def parse
      document
    end

    private

    attr_reader :token_name

    def pos
      @lexer.pos
    end

    def document
      loc = pos
      Nodes::Document.new loc, definition_list
    end

    def definition_list
      list = []
      while !@lexer.done?
        list << definition
      end
      list
    end

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
      expect_token :ON
      directive_locations = self.directive_locations
      Nodes::DirectiveDefinition.new(loc, desc, name, arguments_definition, directive_locations)
    end

    def directive_locations
      list = [directive_location]
      while at?(:PIPE)
        accept_token
        list << directive_location
      end
      list
    end

    def directive_location
      loc = pos
      directive = expect_token_value :IDENTIFIER

      case directive
      when "QUERY", "MUTATION", "SUBSCRIPTION", "FIELD", "FRAGMENT_DEFINITION", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"
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
      list
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
      list
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
      list = [named_type]
      while at?(:PIPE)
        accept_token
        list << named_type
      end
      list
    end

    def interface_type_definition desc
      loc = pos
      expect_token :INTERFACE
      name = self.name
      directives           = if at?(:DIR_SIGN); self.directives; end
      fields_definition   = if at?(:LCURLY); self.fields_definition; end
      Nodes::InterfaceTypeDefinition.new(loc, desc, name, directives, fields_definition)
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
      list
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
      list
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
      list = [self.named_type]
      while true
        accept_token if at?(:AMP)
        break unless at?(:IDENTIFIER)
        list << self.named_type
      end
      list
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
      list
    end

    def executable_definition
      if at?(:FRAGMENT)
        fragment_definition
      else
        operation_definition
      end
    end

    def fragment_definition
      loc = pos
      expect_token :FRAGMENT
      expect_token(:IDENTIFIER) if at?(:ON)
      name = self.name
      tc = self.type_condition
      directives = if at?(:DIR_SIGN)
        self.directives
      end

      Nodes::FragmentDefinition.new(loc, name, tc, directives, selection_set)
    end

    def operation_definition
      loc = pos
      case token_name
      when :QUERY, :MUTATION, :SUBSCRIPTION
        type = self.operation_type
        ident                = if at?(:IDENTIFIER); name; end
        variable_definitions = if at?(:LPAREN); self.variable_definitions; end
        directives           = if at?(:DIR_SIGN); self.directives; end
      end

      Nodes::OperationDefinition.new(
        loc,
        type,
        ident,
        variable_definitions,
        directives,
        selection_set
      )
    end

    def selection_set
      expect_token(:LCURLY)
      list = []
      while !at?(:RCURLY)
        list << selection
      end
      expect_token(:RCURLY)
      list
    end

    def selection
      if at?(:ELLIPSIS)
        selection_fragment
      else
        field
      end
    end

    def selection_fragment
      expect_token :ELLIPSIS

      case token_name
      when :ON, :DIR_SIGN, :LCURLY then inline_fragment
      when :IDENTIFIER then fragment_spread
      else
        expect_token :IDENTIFIER
      end
    end

    def fragment_spread
      loc = pos
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end

      expect_token(:IDENTIFIER) if at?(:ON)

      Nodes::FragmentSpread.new(loc, name, directives)
    end

    def inline_fragment
      loc = pos
      type_condition = if at?(:ON)
        self.type_condition
      end

      directives = if at?(:DIR_SIGN)
        self.directives
      end

      Nodes::InlineFragment.new(loc, type_condition, directives, selection_set)
    end

    def type_condition
      loc = pos
      expect_token :ON
      Nodes::TypeCondition.new(loc, named_type)
    end

    def field
      loc = pos
      name = self.name

      aliaz = nil

      if at?(:COLON)
        expect_token(:COLON)
        aliaz = name
        name = self.name
      end

      arguments = if at?(:LPAREN); self.arguments; end
      directives = if at?(:DIR_SIGN); self.directives; end
      selection_set = if at?(:LCURLY); self.selection_set; end

      Nodes::Field.new(loc, aliaz, name, arguments, directives, selection_set)
    end

    def operation_type
      val = if at?(:QUERY)
        "query"
      elsif at?(:MUTATION)
        "mutation"
      elsif at?(:SUBSCRIPTION)
        "subscription"
      else
        expect_token(:QUERY)
      end
      accept_token
      val
    end

    def directives
      list = []
      while at?(:DIR_SIGN)
        list << directive
      end
      list
    end

    def directive
      loc = pos
      expect_token(:DIR_SIGN)
      name = self.name
      arguments = if at?(:LPAREN)
        self.arguments
      end

      Nodes::Directive.new(loc, name, arguments)
    end

    def arguments
      expect_token(:LPAREN)
      args = []
      while !at?(:RPAREN)
        args << argument
      end
      expect_token(:RPAREN)
      args
    end

    def argument
      loc = pos
      name = self.name
      expect_token(:COLON)
      Nodes::Argument.new(loc, name, value)
    end

    def variable_definitions
      expect_token(:LPAREN)
      defs = []
      while !at?(:RPAREN)
        defs << variable_definition
      end
      expect_token(:RPAREN)
      defs
    end

    def variable_definition
      loc = pos
      var = variable
      expect_token(:COLON)
      type = self.type
      default_value = if at?(:EQUALS)
        self.default_value
      end

      Nodes::VariableDefinition.new(loc, var, type, default_value)
    end

    def default_value
      expect_token(:EQUALS)
      value
    end

    def value
      case token_name
      when :INT then int_value
      when :FLOAT then float_value
      when :STRING then string_value
      when :TRUE, :FALSE then boolean_value
      when :NULL then null_value
      when :IDENTIFIER then enum_value
      when :LBRACKET then list_value
      when :LCURLY then object_value
      when :VAR_SIGN then variable
      else
        expect_token :INT
      end
    end

    def object_value
      start = pos
      expect_token(:LCURLY)
      list = []
      while !at?(:RCURLY)
        loc = pos
        n = name
        expect_token(:COLON)
        list << Nodes::ObjectField.new(loc, n, value)
      end
      expect_token(:RCURLY)
      Nodes::ObjectValue.new(start, list)
    end

    def list_value
      loc = pos
      expect_token(:LBRACKET)
      list = []
      while !at?(:RBRACKET)
        list << value
      end
      expect_token(:RBRACKET)
      Nodes::ListValue.new(loc, list)
    end

    def enum_value
      Nodes::EnumValue.new(pos, expect_token_value(:IDENTIFIER))
    end

    def float_value
      Nodes::FloatValue.new(pos, expect_token_value(:FLOAT))
    end

    def int_value
      Nodes::IntValue.new(pos, expect_token_value(:INT))
    end

    def string_value
      Nodes::StringValue.new(pos, expect_string_value)
    end

    def boolean_value
      if at?(:TRUE)
        accept_token
        Nodes::BooleanValue.new(pos, "true")
      elsif at?(:FALSE)
        accept_token
        Nodes::BooleanValue.new(pos, "false")
      else
        expect_token(:TRUE)
      end
    end

    def null_value
      expect_token :NULL
      Nodes::NullValue.new(pos, "null")
    end

    def type
      type = case token_name
      when :IDENTIFIER then named_type
      when :LBRACKET then list_type
      end

      if at?(:BANG)
        Nodes::NotNullType.new pos, type
        expect_token(:BANG)
      end
      type
    end

    def list_type
      loc = pos
      expect_token(:LBRACKET)
      type = Nodes::ListType.new(loc, self.type)
      expect_token(:RBRACKET)
      type
    end

    def named_type
      Nodes::NamedType.new(pos, name)
    end

    def variable
      return unless at?(:VAR_SIGN)
      loc = pos
      accept_token
      Nodes::Variable.new loc, name
    end

    def name
      case token_name
      when :IDENTIFIER then accept_token_value
      when :TYPE then
        accept_token
        "type"
      when :QUERY then
        accept_token
        "query"
      when :INPUT then
        accept_token
        "input"
      else
        expect_token_value(:IDENTIFIER)
      end
    end

    def accept_token
      @token_name = @lexer.advance
    end

    # Only use when we care about the accepted token's value
    def accept_token_value
      token_value = @lexer.token_value
      accept_token
      token_value
    end

    def expect_token tok
      unless at?(tok)
        raise UnexpectedToken, "Expected token #{tok}, actual: #{token_name} #{@lexer.token_value} line: #{@lexer.line}"
      end
      accept_token
    end

    # Only use when we care about the expected token's value
    def expect_token_value tok
      token_value = @lexer.token_value
      expect_token tok
      token_value
    end

    def expect_string_value
      token_value = @lexer.string_value
      expect_token :STRING
      token_value
    end

    def at? tok
      token_name == tok
    end
  end
end
