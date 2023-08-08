require "tinygql/lexer"
require "tinygql/nodes"

module TinyGQL
  class Parser
    def initialize doc
      @lexer = Lexer.new doc
      @token = @lexer.next_token
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
      while @token
        list << definition
      end
      list
    end

    def definition
      executable_definition || type_system_definition || type_system_extension
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
      raise "unexpected token" if at?(:ON)
      name = self.name
      tc = self.type_condition
      directives = if at?(:DIR_SIGN)
        self.directives
      end

      Nodes::FragmentDefinition.new(name, tc, directives, selection_set)
    end

    def operation_definition
      case @token.first
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

      case @token.first
      when :ON, :DIR_SIGN, :LCURLY then inline_fragment
      when :IDENTIFIER then fragment_spread
      else
        p @token
        p @lexer
        raise
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
      expect_tokens([:QUERY, :MUTATION, :SUBSCRIPTION]).last
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
      case @token.first
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
        p @token
        raise @token.first
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
      Nodes::FloatValue.new(expect_token(:IDENTIFIER).last)
    end

    def float_value
      Nodes::FloatValue.new(expect_token(:FLOAT).last)
    end

    def int_value
      Nodes::IntValue.new(expect_token(:INT).last)
    end

    def string_value
      Nodes::StringValue.new(expect_token(:STRING).last)
    end

    def boolean_value
      Nodes::BooleanValue.new(expect_tokens([:TRUE, :FALSE]).last)
    end

    def null_value
      Nodes::NullValue.new(expect_token(:NULL).last)
    end

    def type
      type = case @token.first
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
      case @token.first
      when :IDENTIFIER, :INPUT, :QUERY then accept_token.last
      else
        expect_token(:IDENTIFIER).last
      end
    end

    private

    def accept_token
      token = @token
      @token = @lexer.next_token
      token
    end

    def expect_token tok
      unless at?(tok)
        p @token
        p @lexer
        raise "Expected token #{tok}, actual: #{@token.first}"
      end
      accept_token
    end

    def expect_tokens toks
      unless toks.any? { |tok| at?(tok) }
        p @token
        raise "Expected token #{tok}, actual: #{@token.first}"
      end
      accept_token
    end

    def at? tok
      @token.first == tok
    end
  end
end
