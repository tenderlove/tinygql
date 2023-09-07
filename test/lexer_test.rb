require "helper"

module TinyGQL
  class LexerTest < Test
    PUNC_LUT = {"!"=>[:BANG, "!"],
                "$"=>[:VAR_SIGN, "$"],
                "("=>[:LPAREN, "("],
                ")"=>[:RPAREN, ")"],
                "..."=>[:ELLIPSIS, "..."],
                ":"=>[:COLON, ":"],
                "="=>[:EQUALS, "="],
                "@"=>[:DIR_SIGN, "@"],
                "["=>[:LBRACKET, "["],
                "]"=>[:RBRACKET, "]"],
                "{"=>[:LCURLY, "{"],
                "|"=>[:PIPE, "|"],
                "}"=>[:RCURLY, "}"]}

    def test_punc
      %w{ ! $ ( ) ... : = @ [ ] { | } }.each do |punc|
        lexer = Lexer.new punc
        token = lexer.next_token
        expected = PUNC_LUT[punc]
        assert_equal(expected, token)
      end
    end

    def test_regular_string
      str = "hello\n# foo\n\"world\"# lol \nlol"
      lexer = Lexer.new str
      assert_equal [:IDENTIFIER, "hello"], lexer.next_token
      assert_equal [:STRING, "world"], lexer.next_token
      assert_equal [:IDENTIFIER, "lol"], lexer.next_token
    end

    def test_multiline_comment
      str = "hello\n# foo\n# lol \nlol"
      lexer = Lexer.new str
      assert_equal [:IDENTIFIER, "hello"], lexer.next_token
      assert_equal [:IDENTIFIER, "lol"], lexer.next_token
    end

    def test_int
      str = "1"
      lexer = Lexer.new str
      assert_equal [:INT, "1"], lexer.next_token
    end

    def test_float
      str = "1.2"
      lexer = Lexer.new str
      assert_equal [:FLOAT, "1.2"], lexer.next_token
    end

    def test_block_string
      doc = <<-eos
"""

      block string uses \\"""

"""
      eos
      lexer = Lexer.new doc
      assert_equal :STRING, lexer.next_token.first
    end

    def test_tokenize
      lexer = Lexer.new "on"
      token = lexer.next_token
      assert_equal [:ON, "on"], token
    end

    def test_multi_tok
      doc = <<-eod
mutation {
  likeStory(storyID: 12345) {
    story {
      likeCount
    }
  }
}
eod
      lexer = Lexer.new doc
      toks = []
      while tok = lexer.next_token
        toks << tok
      end
      assert_equal [[:MUTATION, "mutation"],
                    [:LCURLY, "{"],
                    [:IDENTIFIER, "likeStory"],
                    [:LPAREN, "("],
                    [:IDENTIFIER, "storyID"],
                    [:COLON, ":"],
                    [:INT, "12345"],
                    [:RPAREN, ")"],
                    [:LCURLY, "{"],
                    [:IDENTIFIER, "story"],
                    [:LCURLY, "{"],
                    [:IDENTIFIER, "likeCount"],
                    [:RCURLY, "}"],
                    [:RCURLY, "}"],
                    [:RCURLY, "}"]], toks
    end

    def test_lex_4
      words = ["true", "null", "enum", "type"]
      doc = words.join(" ")

      lexer = Lexer.new doc
      toks = []
      while tok = lexer.next_token
        toks << tok
      end

      assert_equal words.map { |x| [x.upcase.to_sym, x] }, toks
    end

    def test_lex_5
      words = ["input", "false", "query", "union"]
      doc = words.join(" ")

      lexer = Lexer.new doc
      toks = []
      while tok = lexer.next_token
        toks << tok
      end

      assert_equal words.map { |x| [x.upcase.to_sym, x] }, toks
    end

    def test_lex_6
      words = ["extend", "scalar", "schema"]
      doc = words.join(" ")

      lexer = Lexer.new doc
      toks = []
      while tok = lexer.next_token
        toks << tok
      end

      assert_equal words.map { |x| [x.upcase.to_sym, x] }, toks
    end

    def test_lex_8
      words = ["mutation", "fragment"]
      doc = words.join(" ")

      lexer = Lexer.new doc
      toks = []
      while tok = lexer.next_token
        toks << tok
      end

      assert_equal words.map { |x| [x.upcase.to_sym, x] }, toks
    end

    def test_lex_9
      words = ["interface", "directive"]
      doc = words.join(" ")

      lexer = Lexer.new doc
      toks = []
      while tok = lexer.next_token
        toks << tok
      end

      assert_equal words.map { |x| [x.upcase.to_sym, x] }, toks
    end

    def test_kw_lex
      words = ["on", "fragment", "true", "false", "null", "query", "mutation", "subscription", "schema", "scalar", "type", "extend", "implements", "interface", "union", "enum", "input", "directive", "repeatable"]
      doc = words.join(" ")

      lexer = Lexer.new doc
      toks = []
      while tok = lexer.next_token
        toks << tok
      end

      assert_equal words.map { |x| [x.upcase.to_sym, x] }, toks
    end

    def test_looks_like_kw
      words = ["fragment", "fragments"]
      doc = words.join(" ")

      lexer = Lexer.new doc
      toks = []
      while tok = lexer.advance
        toks << tok
      end

      assert_equal [:FRAGMENT, :IDENTIFIER], toks
    end

    def test_num_with_dots
      lexer = Lexer.new "1...2"
      toks = []
      while tok = lexer.advance
        toks << tok
      end

      assert_equal [:INT, :ELLIPSIS, :INT], toks
    end
  end
end
