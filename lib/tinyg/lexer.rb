# frozen_string_literal: true

require "strscan"

module TinyG
  class Lexer
    IDENTIFIER =    /[_A-Za-z][_0-9A-Za-z]*/
    NEWLINE =       /[\c\r\n]/
    BLANK   =       /[, \t]+/
    COMMENT =       /#[^\n\r]*/
    INT =           /[-]?(?:[0]|[1-9][0-9]*)/
    FLOAT_DECIMAL = /[.][0-9]+/
    FLOAT_EXP =     /[eE][+-]?[0-9]+/
    FLOAT =         /#{INT}(#{FLOAT_DECIMAL}#{FLOAT_EXP}|#{FLOAT_DECIMAL}|#{FLOAT_EXP})/

    module Literals
      ON =            /on\b/
      FRAGMENT =      /fragment\b/
      TRUE =          /true\b/
      FALSE =         /false\b/
      NULL =          /null\b/
      QUERY =         /query\b/
      MUTATION =      /mutation\b/
      SUBSCRIPTION =  /subscription\b/
      SCHEMA =        /schema\b/
      SCALAR =        /scalar\b/
      TYPE =          /type\b/
      EXTEND =        /extend\b/
      IMPLEMENTS =    /implements\b/
      INTERFACE =     /interface\b/
      UNION =         /union\b/
      ENUM =          /enum\b/
      INPUT =         /input\b/
      DIRECTIVE =     /directive\b/
      REPEATABLE =    /repeatable\b/
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
      key = Literals.const_get(n)
      key = key.is_a?(Regexp) ? key.source.gsub(/(\\b|\\)/, '') : key
      o[key] = n
    }

    SOURCE_CHARACTER = /[\u0009\u000A\u000D\u0020-\uFFFF]/
    STRING_CHARACTER = %r{
      [\u0009\u000A\u000D\u0020-\uFFFF]
    }x

    LIT = Regexp.union(Literals.constants.map { |n| Literals.const_get(n) })

    QUOTED_STRING = %r{#{QUOTE} (?:#{STRING_CHAR})* #{QUOTE}}x
    BLOCK_STRING = %r{
        #{BLOCK_QUOTE}
    (?: [^"\\]               |  # Any characters that aren't a quote or slash
    (?<!") ["]{1,2} (?!") |  # Any quotes that don't have quotes next to them
    \\"{0,3}(?!")         |  # A slash followed by <= 3 quotes that aren't followed by a quote
    \\                    |  # A slash
    "{1,2}(?!")              # 1 or 2 " followed by something that isn't a quote
    )*
    (?:"")?
        #{BLOCK_QUOTE}
    }xm

    # # catch-all for anything else. must be at the bottom for precedence.
    UNKNOWN_CHAR =         /./

    def initialize string
      raise unless string.valid_encoding?

      @scan = StringScanner.new string
      @line = 1
    end

    def next_token
      return if @scan.eos?

      pos = @scan.pos

      case
      when str = @scan.scan(FLOAT)         then emit(:FLOAT, pos, @scan.pos, str)
      when str = @scan.scan(INT)           then emit(:INT, pos, @scan.pos, str)
      when str = @scan.scan(LIT)           then emit(LIT_NAME_LUT[str], pos, @scan.pos, -str)
      when str = @scan.scan(IDENTIFIER)    then emit(:IDENTIFIER, pos, @scan.pos, str)
      when str = @scan.scan(BLOCK_STRING)  then emit_block(pos, @scan.pos, str.gsub(/\A#{BLOCK_QUOTE}|#{BLOCK_QUOTE}\z/, ''))
      when str = @scan.scan(QUOTED_STRING) then emit_string(pos, @scan.pos, str.gsub(/^"|"$/, ''))
      when str = @scan.scan(COMMENT)       then record_comment(pos, @scan.pos, str)
      when str = @scan.scan(NEWLINE)
        @line += 1
        next_token
      when @scan.scan(BLANK)
        next_token
      when str = @scan.scan(UNKNOWN_CHAR) then emit(:UNKNOWN_CHAR, pos, @scan.pos, str)
      else
        # This should never happen since `UNKNOWN_CHAR` ensures we make progress
        raise "Unknown string?"
      end
    end

    def emit token_name, ts, te, token_value
      [token_name, token_value]
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

    def record_comment(ts, te, str)
      next_token
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

    def emit_block(ts, te, value)
      line_incr = value.count("\n")
      value = trim_whitespace(value)
      @line += line_incr
      emit_string(ts, te, value)
    end

    def emit_string(ts, te, value)
      if !value.valid_encoding? || !value.match?(VALID_STRING)
        emit(:BAD_UNICODE_ESCAPE, ts, te, value)
      else
        replace_escaped_characters_in_place(value)

        if !value.valid_encoding?
          emit(:BAD_UNICODE_ESCAPE, ts, te, value)
        else
          emit(:STRING, ts, te, value)
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
