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

    KEYWORDS = [
      "on",
      "fragment",
      "true",
      "false",
      "null",
      "query",
      "mutation",
      "subscription",
      "schema",
      "scalar",
      "type",
      "extend",
      "implements",
      "interface",
      "union",
      "enum",
      "input",
      "directive",
      "repeatable"
    ].freeze

    KW_RE = /#{Regexp.union(KEYWORDS.sort)}\b/

    KW_FP3 = KEYWORDS.filter {
      |w| w.length >= 4
    }. map {
      |w| [
        w.getbyte(1) * 169 + w.getbyte(2) * 13 + w.getbyte(3),
        w.upcase.to_sym
      ]
    }.to_h.freeze

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
      EQUALS =        '='
      BANG =          '!'
      PIPE =          '|'
      AMP =           '&'
    end

    ELLIPSIS =      '...'

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

    PUNCT_LUT = Literals.constants.each_with_object([]) { |n, o|
      o[Literals.const_get(n).ord] = n
    }

    LEAD_BYTES = Array.new(255) { 0 }

    module LeadBytes
      INT = 1 << 0
      KW = 1 << 1
      ELLIPSIS = 1 << 2
      STRING = 1 << 3
      PUNCT = 1 << 4
      IDENT = 1 << 5
    end

    10.times { |i| LEAD_BYTES[i.to_s.ord] |= LeadBytes::INT }

    ("A".."Z").each { |chr| LEAD_BYTES[chr.ord] |= LeadBytes::IDENT }
    ("a".."z").each { |chr| LEAD_BYTES[chr.ord] |= LeadBytes::IDENT }
    LEAD_BYTES['_'.ord] |= LeadBytes::IDENT

    KEYWORDS.each { |kw| LEAD_BYTES[kw.getbyte(0)] |= LeadBytes::KW }

    LEAD_BYTES['.'.ord] |= LeadBytes::ELLIPSIS

    LEAD_BYTES['"'.ord] |= LeadBytes::STRING

    Literals.constants.each_with_object([]) { |n, o|
      LEAD_BYTES[Literals.const_get(n).ord] |= LeadBytes::PUNCT
    }

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

      @string = string
      @scan = StringScanner.new string
      @start = nil
      @len = nil
    end

    attr_reader :start

    def line
      @scan.string[0, @scan.pos].count("\n") + 1
    end

    def done?
      @scan.eos?
    end

    def advance
      @scan.skip(IGNORE)

      return false if @scan.eos?

      @start = @scan.pos

      lead_byte = @string.getbyte(@start)
      lead_code = LEAD_BYTES[lead_byte]

      if lead_code == LeadBytes::PUNCT
        @scan.pos += 1
        PUNCT_LUT[lead_byte]

      elsif lead_code & LeadBytes::IDENT != 0
        @len = @scan.skip(IDENTIFIER)
        if lead_code & LeadBytes::KW != 0 then
          if @len >= 4 then
            key = (@string.getbyte(@start + 2) << 8) + @string.getbyte(@start + 1)

            tk = KW_LUT[
              (key * 19637591) >> 27 & 0x1f
            ]

            if tk then
              @scan.pos = @start
              return tk if @scan.skip(KW_RE) == @len
              @scan.pos = @start + @len
            end
          elsif @len == 2 then
            return :ON if lead_byte == 111 && @string.getbyte(@start+1) == 110
          end
        end
        :IDENTIFIER

      elsif lead_code == LeadBytes::INT
        @len = @scan.skip(NUMERIC)
        @scan[1] ? :FLOAT : :INT

      elsif lead_code == LeadBytes::ELLIPSIS
        2.times do |i|
          raise unless @string.getbyte(@start + i + 1) == 46
        end
        @scan.pos += 3
        :ELLIPSIS

      elsif lead_code == LeadBytes::STRING
        @len = @scan.skip(BLOCK_STRING) || @scan.skip(QUOTED_STRING)
        raise unless @len
        :STRING

      else
        @scan.pos += 1
        :UNKNOWN_CHAR
      end
    end

    def token_value
      @string.byteslice(@start, @len)
    end

    def string_value
      str = token_value
      block = str.start_with?('"""')
      str.gsub!(/\A"*|"*\z/, '')

      if block
        emit_block str
      else
        emit_string str
      end
    end

    def next_token
      return unless tok = advance
      val = case tok
      when :STRING then string_value
      when :ELLIPSIS then
        @string.byteslice(@scan.pos - 3, 3)
      when *Literals.constants
        @string.byteslice(@scan.pos - 1, 1)
      else
        token_value
      end

      [tok, val]
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
          value
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

    KW_LUT =
      [nil,
        :FRAGMENT,
        nil,
        nil,
        nil,
        :SCHEMA,
        nil,
        :SUBSCRIPTION,
        :INTERFACE,
        :MUTATION,
        :EXTEND,
        nil,
        :UNION,
        nil,
        :ENUM,
        :TRUE,
        nil,
        :REPEATABLE,
        :IMPLEMENTS,
        :INPUT,
        :TYPE,
        nil,
        nil,
        nil,
        :QUERY,
        nil,
        nil,
        :FALSE,
        nil,
        :DIRECTIVE,
        :NULL,
        :SCALAR]
  end
end
