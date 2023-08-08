require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task :test => "lib/tinygql/nodes.rb"

task default: :test

file "lib/tinygql/nodes.rb" => "lib/tinygql/nodes.yml" do |t|
  require "psych"
  require "erb"
  info = Psych.load_file t.source
  Node = Struct.new(:name, :parent, :fields) do
    def has_children?; fields.length > 0; end

    def human_name
      name.gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
        gsub(/([a-z\d])([A-Z])/,'\1_\2').
        tr("-", "_").
        downcase
    end

    def children
      buf = ["ary = []"]

      fields.each do |field|
        case field.type
        when "list"
          x = "ary.concat(#{field.name})"
          if field.nullable?
            x << " if #{field.name}"
          end
          buf << x
        when "node"
          x = "ary << #{field.name}"
          if field.nullable?
            x << " if #{field.name}"
          end
          buf << x
        end
      end

      buf << "ary"
      buf.join("; ")
    end
  end
  Field = Struct.new :_name, :type do
    def name
      _name.sub(/\?$/, '')
    end

    def nullable?
      _name.end_with?("?")
    end
  end
  nodes = info["nodes"].map { |n|
    Node.new(n["name"], n["parent"] || "Node", (n["fields"] || []).map { |f|
      name = f
      type = "node"
      if Hash === f
        (name, type) = *f.to_a.first
      end
      Field.new name, type
    })
  }
  erb = ERB.new File.read("lib/tinygql/nodes.rb.erb"), trim_mode: "-"
  File.binwrite t.name, erb.result(binding)
end
