require "tinyg/lexer"
require "tinyg/nodes"

module TinyG
  class Parser
    def initialize doc
      @lexer = Lexer.new doc
    end

    def parse
      @token = @lexer.next_token
      document
    end

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
      operation_definition || fragment_definition
    end

    def operation_definition
      case @token.first
      when :QUERY, :MUTATION, :SUBSCRIPTION
        type = self.operation_type
        ident = if at?(:IDENTIFIER)
          name
        end

        Nodes::OperationDefinition.new(
          type,
          ident,
          variable_definitions,
          directives,
          selection_set
        )
      else
        selection_set
      end
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
      case @token.first
      when :IDENTIFIER then field
      else
        raise @token.first
      end
    end

    def field
      alias_or_name = self.name

      aliaz = nil
      name = nil

      if at?(:IDENTIFIER)
        aliaz = alias_or_name
        name = self.name
      else
        aliaz = nil
        name = alias_or_name
      end

      if at?(:COLON)
        expect_token(:COLON)
        aliaz = alias_or_name
        name = self.name
      end

      arguments = if at?(:LPAREN)
        self.arguments
      else
        nil
      end

      directives = self.directives

      selection_set = if at?(:LCURLY)
        self.selection_set
      else
        nil
      end

      Nodes::Field.new(aliaz, name, arguments, directives, selection_set)
    end

    def operation_type
      expect_tokens([:QUERY, :MUTATION, :SUBSCRIPTION]).last
    end

    def directives
      return unless at?(:DIR_SIGN)

      list = []
      while at?(:DIR_SIGN)
        list << directive
      end
      list
    end

    def directive
      expect_token(:DIR_SIGN)
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
      return unless @token.first == :LPAREN
      accept_token
      defs = []
      while @token.first != :RPAREN
        defs << variable_definition
      end
      expect_token(:RPAREN)
      defs
    end

    def variable_definition
      var = variable
      return unless var
      expect_token(:COLON)
      default_value
      Nodes::VariableDefinition.new(var, type, default_value)
    end

    def default_value
      return unless at?(:EQUALS)
      accept_token

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
      else
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
        NotNullType.new type
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
      expect_token(:IDENTIFIER).last
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
