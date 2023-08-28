# frozen_string_literal: true

require "strscan"

module TinyGQL
  class Lexer
    IDENTIFIER =    /[_A-Za-z][_0-9A-Za-z]*\b/
    IGNORE   =       %r{
      (?:
        [, \c\r\n\t]+ |
        \#.*$
      )*
    }x
    INT =           /[-]?(?:[0]|[1-9][0-9]*)/
    FLOAT_DECIMAL = /[.][0-9]+/
    FLOAT_EXP =     /[eE][+-]?[0-9]+/
    NUMERIC =  /#{INT}(#{FLOAT_DECIMAL}#{FLOAT_EXP}|#{FLOAT_DECIMAL}|#{FLOAT_EXP})?/

    KEYWORDS = {
      "on" => :ON,
      "fragment" => :FRAGMENT,
      "true" => :TRUE,
      "false" => :FALSE,
      "null" => :NULL,
      "query" => :QUERY,
      "mutation" => :MUTATION,
      "subscription" => :SUBSCRIPTION,
      "schema" => :SCHEMA,
      "scalar" => :SCALAR,
      "type" => :TYPE,
      "extend" => :EXTEND,
      "implements" => :IMPLEMENTS,
      "interface" => :INTERFACE,
      "union" => :UNION,
      "enum" => :ENUM,
      "input" => :INPUT,
      "directive" => :DIRECTIVE,
      "repeatable" => :REPEATABLE
    }.freeze

    module Literals
      LCURLY =        '{'
      RCURLY =        '}'
      LPAREN =        '('
      RPAREN =        ')'
      LBRACKET =      '['
      RBRACKET =      ']'
      COLON =         ':'
      VAR_SIGN =      '$'
      DIR_SIGN =      '@'
      ELLIPSIS =      '...'
      EQUALS =        '='
      BANG =          '!'
      PIPE =          '|'
      AMP =           '&'
    end

    include Literals

    QUOTE =         '"'
    UNICODE_DIGIT = /[0-9A-Za-z]/
    FOUR_DIGIT_UNICODE = /#{UNICODE_DIGIT}{4}/
    N_DIGIT_UNICODE = %r{#{LCURLY}#{UNICODE_DIGIT}{4,}#{RCURLY}}x
    UNICODE_ESCAPE = %r{\\u(?:#{FOUR_DIGIT_UNICODE}|#{N_DIGIT_UNICODE})}
    # # https://graphql.github.io/graphql-spec/June2018/#sec-String-Value
    STRING_ESCAPE = %r{[\\][\\/bfnrt]}
    BLOCK_QUOTE =   '"""'
    ESCAPED_QUOTE = /\\"/;
    STRING_CHAR = /#{ESCAPED_QUOTE}|[^"\\]|#{UNICODE_ESCAPE}|#{STRING_ESCAPE}/

    LIT_NAME_LUT = Literals.constants.each_with_object({}) { |n, o|
      o[Literals.const_get(n)] = n
    }

    LIT = Regexp.union(Literals.constants.map { |n| Literals.const_get(n) })

    QUOTED_STRING = %r{#{QUOTE} ((?:#{STRING_CHAR})*) #{QUOTE}}x
    BLOCK_STRING = %r{
        #{BLOCK_QUOTE}
    ((?: [^"\\]               |  # Any characters that aren't a quote or slash
    (?<!") ["]{1,2} (?!") |  # Any quotes that don't have quotes next to them
    \\"{0,3}(?!")         |  # A slash followed by <= 3 quotes that aren't followed by a quote
    \\                    |  # A slash
    "{1,2}(?!")              # 1 or 2 " followed by something that isn't a quote
    )*
    (?:"")?)
        #{BLOCK_QUOTE}
    }xm

    def initialize string
      raise unless string.valid_encoding?

      @scan = StringScanner.new string
      @token_name = nil
      @token_value = nil
    end

    def pos
      @scan.pos
    end

    def line
      @scan.string[0, @scan.pos].count("\n") + 1
    end

    def done?
      @scan.eos?
    end

    def advance
      @scan.skip(IGNORE)

      case
      when str = @scan.scan(LIT)           then emit(LIT_NAME_LUT[str], str)
      when str = @scan.scan(IDENTIFIER)    then emit(KEYWORDS.fetch(str, :IDENTIFIER), str)
      when @scan.skip(BLOCK_STRING)        then emit_block(@scan[1])
      when @scan.skip(QUOTED_STRING)       then emit_string(@scan[1])
      when str = @scan.scan(NUMERIC)       then emit(@scan[1] ? :FLOAT : :INT, str)
      when @scan.eos?                      then emit(nil, nil) and return false
      else
        emit(:UNKNOWN_CHAR, @scan.getch)
      end
    end

    attr_reader :token_name, :token_value

    def emit token_name, token_value
      @token_name = token_name
      @token_value = token_value
      true
    end

    def next_token
      advance && [@token_name, @token_value]
    end

    # Replace any escaped unicode or whitespace with the _actual_ characters
    # To avoid allocating more strings, this modifies the string passed into it
    def replace_escaped_characters_in_place(raw_string)
      raw_string.gsub!(ESCAPES, ESCAPES_REPLACE)
      raw_string.gsub!(UTF_8) do |_matched_str|
        codepoint_1 = ($1 || $2).to_i(16)
        codepoint_2 = $3

        if codepoint_2
          codepoint_2 = codepoint_2.to_i(16)
          if (codepoint_1 >= 0xD800 && codepoint_1 <= 0xDBFF) && # leading surrogate
              (codepoint_2 >= 0xDC00 && codepoint_2 <= 0xDFFF) # trailing surrogate
            # A surrogate pair
            combined = ((codepoint_1 - 0xD800) * 0x400) + (codepoint_2 - 0xDC00) + 0x10000
            [combined].pack('U'.freeze)
          else
            # Two separate code points
            [codepoint_1].pack('U'.freeze) + [codepoint_2].pack('U'.freeze)
          end
        else
          [codepoint_1].pack('U'.freeze)
        end
      end
      nil
    end

    ESCAPES = /\\["\\\/bfnrt]/
    ESCAPES_REPLACE = {
      '\\"' => '"',
      "\\\\" => "\\",
      "\\/" => '/',
      "\\b" => "\b",
      "\\f" => "\f",
      "\\n" => "\n",
      "\\r" => "\r",
      "\\t" => "\t",
    }
    UTF_8 = /\\u(?:([\dAa-f]{4})|\{([\da-f]{4,})\})(?:\\u([\dAa-f]{4}))?/i
    VALID_STRING = /\A(?:[^\\]|#{ESCAPES}|#{UTF_8})*\z/o

    def emit_block(value)
      value = trim_whitespace(value)
      emit_string(value)
    end

    def emit_string(value)
      if !value.valid_encoding? || !value.match?(VALID_STRING)
        emit(:BAD_UNICODE_ESCAPE, value)
      else
        replace_escaped_characters_in_place(value)

        if !value.valid_encoding?
          emit(:BAD_UNICODE_ESCAPE, value)
        else
          emit(:STRING, value)
        end
      end
    end

    def trim_whitespace(str)
      # Early return for the most common cases:
      if str == ""
        return "".dup
      elsif !(has_newline = str.include?("\n")) && !(str.start_with?(" "))
        return str
      end

      lines = has_newline ? str.split("\n") : [str]
      common_indent = nil

      # find the common whitespace
      lines.each_with_index do |line, idx|
        if idx == 0
          next
        end
        line_length = line.size
        line_indent = if line.match?(/\A  [^ ]/)
          2
        elsif line.match?(/\A    [^ ]/)
          4
        elsif line.match?(/\A[^ ]/)
          0
        else
          line[/\A */].size
        end
        if line_indent < line_length && (common_indent.nil? || line_indent < common_indent)
          common_indent = line_indent
        end
      end

      # Remove the common whitespace
      if common_indent && common_indent > 0
        lines.each_with_index do |line, idx|
          if idx == 0
            next
          else
            line.slice!(0, common_indent)
          end
        end
      end

      # Remove leading & trailing blank lines
      while lines.size > 0 && lines[0].empty?
        lines.shift
      end
      while lines.size > 0 && lines[-1].empty?
        lines.pop
      end

      # Rebuild the string
      lines.size > 1 ? lines.join("\n") : (lines.first || "".dup)
    end
  end
end
