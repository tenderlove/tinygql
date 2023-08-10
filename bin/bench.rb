# frozen_string_literal: true

$:.unshift(File.expand_path("../lib", __dir__))
require "tinygql"
require "benchmark"

source = File.read(File.expand_path("../test/kitchen-sink.graphql", __dir__))

Benchmark.bm do |x|
  x.report { 10_000.times { TinyGQL::Parser.new(source).parse } }
end
