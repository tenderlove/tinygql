# frozen_string_literal: true

require "tinygql"
require "benchmark/ips"

source = File.read(File.expand_path("../test/kitchen-sink.graphql", __dir__))

files = Dir[File.join(File.expand_path("../benchmark", __dir__), "**/*")].select { |f| File.file? f }

Benchmark.ips do |x|
  x.report "kitchen-sink" do
    TinyGQL.parse source
  end

  files.each do |file_name|
    data = File.read file_name
    name = File.basename(file_name, File.extname(file_name))
    x.report name do
      TinyGQL.parse data
    end
  end
end

module Benchmark
  def self.allocs; yield Allocs; end
end

class Allocs
  def self.report name, &block
    allocs = nil

    2.times do # 2 times to heat caches
      allocs = 10.times.map {
        x = GC.stat(:total_allocated_objects)
        yield
        GC.stat(:total_allocated_objects) - x
      }.inject(:+) / 10
    end

    puts name.rjust(20) + allocs.to_s.rjust(10)
  end
end

print "#" * 30
print " ALLOCATIONS "
puts "#" * 30

Benchmark.allocs do |x|
  x.report "kitchen-sink" do
    TinyGQL.parse source
  end

  files.each do |file_name|
    data = File.read file_name
    name = File.basename(file_name, File.extname(file_name))
    x.report name do
      TinyGQL.parse data
    end
  end
end
