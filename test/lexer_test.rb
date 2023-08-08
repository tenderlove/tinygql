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
        assert_equal(expected || [:ON, "on"], token)
      end
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
  end
end
