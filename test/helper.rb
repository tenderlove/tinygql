ENV["MT_NO_PLUGINS"] = "1"

require "tinyg/parser"
require "minitest/autorun"

Thread.new do
  sleep 5
  Process.kill "QUIT", $$
end

module TinyG
  class Test < Minitest::Test
  end
end
