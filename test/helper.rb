ENV["MT_NO_PLUGINS"] = "1"

require "tinygql/parser"
require "minitest/autorun"

Thread.new do
  sleep 5
  Process.kill "QUIT", $$
end

module TinyGQL
  class Test < Minitest::Test
  end
end
