Gem::Specification.new do |s|
  s.name        = "tinygql"
  s.version     = "0.1.0"
  s.summary     = "A GraphQL parser"
  s.description = "Yet another GraphQL parser written in Ruby."
  s.authors     = ["Aaron Patterson"]
  s.email       = "tenderlove@ruby-lang.org"
  s.files       = `git ls-files -z`.split("\x0") + [
    "lib/tinygql/nodes.rb",
    "lib/tinygql/visitors.rb",
  ]
  s.test_files  = s.files.grep(%r{^test/})
  s.homepage    = "https://github.com/tenderlove/tinygql"
  s.license     = "Apache-2.0"

  s.add_development_dependency("rake", "~> 13.0")
  s.add_development_dependency("minitest", "~> 5.14")
end
