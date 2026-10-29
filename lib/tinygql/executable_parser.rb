# frozen_string_literal: true

require "tinygql/lexer"
require "tinygql/nodes"

module TinyGQL
  # Parses executable documents: operations and fragments.  Parser extends
  # this with the type system definitions used in schemas
  class ExecutableParser
    class UnexpectedToken < StandardError; end

    # Keywords are only reserved in certain positions, everywhere else they
    # are valid names
    KEYWORD_TOKENS = Lexer::KEYWORDS.map { |kw| kw.upcase.to_sym }.freeze

    # Enum values may be any name except true, false, or null
    ENUM_VALUE_KEYWORD_TOKENS = (KEYWORD_TOKENS - [:TRUE, :FALSE, :NULL]).freeze

    def self.parse doc
      new(doc).parse
    end

    def initialize doc
      @lexer = Lexer.new doc
      accept_token
    end

    def parse
      document
    end

    private

    attr_reader :token_name

    def pos
      @lexer.start
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
      list.freeze
    end

    def definition
      case token_name
      when :FRAGMENT, :QUERY, :MUTATION, :SUBSCRIPTION, :LCURLY
        executable_definition
      else
        expect_token :QUERY
      end
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

      Nodes::FragmentDefinition.new(loc, name, tc, directives, fragment_selection_set(name, tc))
    end

    # Hook for parsing the selection set of a fragment definition
    def fragment_selection_set name, type_condition
      selection_set
    end

    def operation_definition
      loc = pos
      case token_name
      when :QUERY, :MUTATION, :SUBSCRIPTION
        type = self.operation_type
        ident                = if name?; name; end
        variable_definitions = if at?(:LPAREN); self.variable_definitions; end
        directives           = if at?(:DIR_SIGN); self.directives; end
      end

      Nodes::OperationDefinition.new(
        loc,
        type,
        ident,
        variable_definitions,
        directives,
        operation_selection_set(type)
      )
    end

    # Hook for parsing the selection set of an operation.  `type` is nil for
    # shorthand queries
    def operation_selection_set type
      selection_set
    end

    def selection_set
      expect_token(:LCURLY)
      list = []
      while !at?(:RCURLY)
        list << selection
      end
      expect_token(:RCURLY)
      list.freeze
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
      else
        if name?
          fragment_spread
        else
          expect_token :IDENTIFIER
        end
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

      Nodes::Field.new(loc, aliaz, name, arguments, directives, selection_set, nil)
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
      list.freeze
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
      args.freeze
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
      defs.freeze
    end

    def variable_definition
      loc = pos
      var = variable if at?(:VAR_SIGN)
      expect_token(:COLON)
      type = self.type
      default_value = if at?(:EQUALS)
        self.default_value
      end
      directives = if at?(:DIR_SIGN); self.directives; end

      Nodes::VariableDefinition.new(loc, var, type, default_value, directives)
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
      when :IDENTIFIER, *ENUM_VALUE_KEYWORD_TOKENS then enum_value
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
      Nodes::ObjectValue.new(start, list.freeze)
    end

    def list_value
      loc = pos
      expect_token(:LBRACKET)
      list = []
      while !at?(:RBRACKET)
        list << value
      end
      expect_token(:RBRACKET)
      Nodes::ListValue.new(loc, list.freeze)
    end

    def enum_value
      case token_name
      when :IDENTIFIER, *ENUM_VALUE_KEYWORD_TOKENS
        Nodes::EnumValue.new(pos, expect_token_value(token_name))
      else
        expect_token(:IDENTIFIER)
      end
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
      loc = pos
      if at?(:TRUE)
        accept_token
        Nodes::BooleanValue.new(loc, "true")
      elsif at?(:FALSE)
        accept_token
        Nodes::BooleanValue.new(loc, "false")
      else
        expect_token(:TRUE)
      end
    end

    def null_value
      loc = pos
      expect_token :NULL
      Nodes::NullValue.new(loc, "null")
    end

    def type
      loc = pos
      type = if at?(:LBRACKET)
        list_type
      else
        named_type
      end

      if at?(:BANG)
        expect_token(:BANG)
        type = Nodes::NotNullType.new loc, type
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
      loc = pos
      expect_token(:VAR_SIGN)
      Nodes::Variable.new loc, name
    end

    def name
      case token_name
      when :IDENTIFIER, *KEYWORD_TOKENS then expect_token_value(token_name)
      else
        expect_token(:IDENTIFIER)
      end
    end

    def name?
      case token_name
      when :IDENTIFIER, *KEYWORD_TOKENS then true
      else
        false
      end
    end

    def accept_token
      @token_name = @lexer.advance
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
