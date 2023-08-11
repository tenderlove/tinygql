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
