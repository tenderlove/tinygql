# frozen_string_literal: true

require "tinygql/lexer"
require "tinygql/nodes"

module TinyGQL
  class Parser
    class UnexpectedToken < StandardError; end

    attr_reader :token_name

    def initialize doc
      @lexer = Lexer.new doc
      @lexer.advance
      @token_name = @lexer.token_name
    end

    def parse
      document
    end

    private

    def document
      Nodes::Document.new definition_list
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
        type_system_definition
      end
    end

    def type_system_extension
      expect_token :EXTEND
      case token_name
      when :TYPE then object_type_extension
      else
        expect_token :FAIL
      end
    end

    def object_type_extension
      expect_token :TYPE
      name = self.name
      implements_interfaces = if at?(:IMPLEMENTS); self.implements_interfaces; end
      directives           = if at?(:DIR_SIGN); self.directives; end
      fields_definition   = if at?(:LCURLY); self.fields_definition; end
      Nodes::ObjectTypeExtension.new(name, implements_interfaces, directives, fields_definition)
    end

    def type_system_definition
      case token_name
      when :SCHEMA then schema_definition
      when :DIRECTIVE then directive_defintion(nil)
      else
        type_definition(nil)
      end
    end

    def directive_defintion desc
      expect_token :DIRECTIVE
      expect_token :DIR_SIGN
      name = self.name
      arguments_definition = if at?(:LPAREN); self.arguments_definition; end
      expect_token :ON
      directive_locations = self.directive_locations
      Nodes::DirectiveDefinition.new(desc, name, arguments_definition, directive_locations)
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
      case token_name
      when "QUERY", "MUTATION", "SUBSCRIPTION", "FIELD", "FRAGMENT_DEFINITION", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"
        Nodes::ExecutableDirectiveLocation.new(accept_token_value)
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
        Nodes::TypeSystemDirectiveLocation.new(accept_token_value)
      else
        expect_token(:IDENTIFIER); nil # error
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
        expect_token :FAIL
      end
    end

    def input_object_type_definition desc
      expect_token :INPUT
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      input_fields_definition = if at?(:LCURLY); self.input_fields_definition; end
      Nodes::InputObjectTypeDefinition.new(desc, name, directives, input_fields_definition)
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
      expect_token :ENUM
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      enum_values_definition = if at?(:LCURLY); self.enum_values_definition; end
      Nodes::EnumTypeDefinition.new(desc, name, directives, enum_values_definition)
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
      description = if at?(:STRING); accept_token_value; end
      enum_value = self.enum_value
      directives = if at?(:DIR_SIGN); self.directives; end
      Nodes::EnumValueDefinition.new(description, enum_value, directives)
    end

    def scalar_type_definition desc
      expect_token :SCALAR
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      Nodes::ScalarTypeDefinition.new(desc, name, directives)
    end

    def union_type_definition desc
      expect_token :UNION
      name = self.name
      directives = if at?(:DIR_SIGN); self.directives; end
      union_member_types = if at?(:EQUALS); self.union_member_types; end
      Nodes::UnionTypeDefinition.new(desc, name, directives, union_member_types)
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
      expect_token :INTERFACE
      name = self.name
      directives           = if at?(:DIR_SIGN); self.directives; end
      fields_definition   = if at?(:LCURLY); self.fields_definition; end
      Nodes::InterfaceTypeDefinition.new(desc, name, directives, fields_definition)
    end

    def object_type_definition desc
      expect_token :TYPE
      name = self.name
      implements_interfaces = if at?(:IMPLEMENTS); self.implements_interfaces; end
      directives           = if at?(:DIR_SIGN); self.directives; end
      fields_definition   = if at?(:LCURLY); self.fields_definition; end

      Nodes::ObjectTypeDefinition.new(desc, name, implements_interfaces, directives, fields_definition)
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
      description = if at?(:STRING); accept_token_value; end
      name = self.name
      arguments_definition = if at?(:LPAREN); self.arguments_definition; end
      expect_token :COLON
      type = self.type
      directives           = if at?(:DIR_SIGN); self.directives; end

      Nodes::FieldDefinition.new(description, name, arguments_definition, type, directives)
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
      description = if at?(:STRING); accept_token_value; end
      name = self.name
      expect_token :COLON
      type = self.type
      default_value = if at?(:EQUALS); self.default_value; end
      directives           = if at?(:DIR_SIGN); self.directives; end
      Nodes::InputValueDefinition.new(description, name, type, default_value, directives)
    end

    def implements_interfaces
      expect_token :IMPLEMENTS
      list = [self.named_type]
      while at?(:AMP)
        accept_token
        list << self.named_type
      end
      list
    end

    def schema_definition
      expect_token :SCHEMA

      directives = if at?(:DIR_SIGN); self.directives; end
      expect_token :LCURLY
      defs = root_operation_type_definition
      expect_token :RCURLY
      Nodes::SchemaDefinition.new(directives, defs)
    end

    def root_operation_type_definition
      list = []
      while !at?(:RCURLY)
        operation_type = self.operation_type
        expect_token :COLON
        list << Nodes::RootOperationTypeDefinition.new(operation_type, named_type)
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
      expect_token :FRAGMENT
      expect_token(:FAIL) if at?(:ON)
      name = self.name
      tc = self.type_condition
      directives = if at?(:DIR_SIGN)
        self.directives
      end

      Nodes::FragmentDefinition.new(name, tc, directives, selection_set)
    end

    def operation_definition
      case token_name
      when :QUERY, :MUTATION, :SUBSCRIPTION
        type = self.operation_type
        ident                = if at?(:IDENTIFIER); name; end
        variable_definitions = if at?(:LPAREN); self.variable_definitions; end
        directives           = if at?(:DIR_SIGN); self.directives; end
      end

      Nodes::OperationDefinition.new(
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
        expect_token :FAIL
      end
    end

    def fragment_spread
      name = self.name
      directives = if at?(:DIR_SIGN)
        self.directives
      end

      Nodes::FragmentSpread.new(name, directives)
    end

    def inline_fragment
      type_condition = if at?(:ON)
        self.type_condition
      end

      directives = if at?(:DIR_SIGN)
        self.directives
      end

      Nodes::InlineFragment.new(type_condition, directives, selection_set)
    end

    def type_condition
      expect_token :ON
      Nodes::TypeCondition.new(named_type)
    end

    def field
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

      Nodes::Field.new(aliaz, name, arguments, directives, selection_set)
    end

    def operation_type
      expect_tokens([:QUERY, :MUTATION, :SUBSCRIPTION])
    end

    def directives
      list = []
      while at?(:DIR_SIGN)
        list << directive
      end
      list
    end

    def directive
      expect_token(:DIR_SIGN)
      name = self.name
      arguments = if at?(:LPAREN)
        self.arguments
      end

      Nodes::Directive.new(name, arguments)
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
      name = self.name
      expect_token(:COLON)
      Nodes::Argument.new(name, value)
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
      var = variable
      expect_token(:COLON)
      type = self.type
      default_value = if at?(:EQUALS)
        self.default_value
      end

      Nodes::VariableDefinition.new(var, type, default_value)
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
        expect_token :FAIL
      end
    end

    def object_value
      expect_token(:LCURLY)
      list = []
      while !at?(:RCURLY)
        n = name
        expect_token(:COLON)
        list << Nodes::ObjectField.new(n, value)
      end
      expect_token(:RCURLY)
      Nodes::ObjectValue.new(list)
    end

    def list_value
      expect_token(:LBRACKET)
      list = []
      while !at?(:RBRACKET)
        list << value
      end
      expect_token(:RBRACKET)
      Nodes::ListValue.new(list)
    end

    def enum_value
      Nodes::EnumValue.new(expect_token_value(:IDENTIFIER))
    end

    def float_value
      Nodes::FloatValue.new(expect_token_value(:FLOAT))
    end

    def int_value
      Nodes::IntValue.new(expect_token_value(:INT))
    end

    def string_value
      Nodes::StringValue.new(expect_token_value(:STRING))
    end

    def boolean_value
      Nodes::BooleanValue.new(expect_tokens([:TRUE, :FALSE]))
    end

    def null_value
      Nodes::NullValue.new(expect_token_value(:NULL))
    end

    def type
      type = case token_name
      when :IDENTIFIER then named_type
      when :LBRACKET then list_type
      end

      if at?(:BANG)
        Nodes::NotNullType.new type
        expect_token(:BANG)
      end
      type
    end

    def list_type
      expect_token(:LBRACKET)
      type = Nodes::ListType.new(self.type)
      expect_token(:RBRACKET)
      type
    end

    def named_type
      Nodes::NamedType.new(name)
    end

    def variable
      return unless at?(:VAR_SIGN)
      accept_token
      Nodes::Variable.new name
    end

    def name
      case token_name
      when :IDENTIFIER, :INPUT, :QUERY, :TYPE then accept_token_value
      else
        expect_token_value(:IDENTIFIER)
      end
    end

    def accept_token
      @lexer.advance
      @token_name = @lexer.token_name
    end

    # Only use when we care about the accepted token's value
    def accept_token_value
      token_value = @lexer.token_value
      accept_token
      token_value
    end

    def expect_token tok
      unless at?(tok)
        raise UnexpectedToken, "Expected token #{tok}, actual: #{token_name} line: #{@lexer.line}"
      end
      accept_token
    end

    # Only use when we care about the expected token's value
    def expect_token_value tok
      token_value = @lexer.token_value
      expect_token tok
      token_value
    end

    def expect_tokens toks
      token_value = @lexer.token_value
      unless toks.any? { |tok| at?(tok) }
        raise UnexpectedToken, "Expected token #{tok}, actual: #{token_name}"
      end
      accept_token
      token_value
    end

    def at? tok
      token_name == tok
    end
  end
end
