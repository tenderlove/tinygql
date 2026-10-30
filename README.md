# TinyGQL

Very experimental GraphQL parser.  It's mostly reusing the lexer from
[GraphQL-Ruby](https://github.com/rmosolgo/graphql-ruby), but the parser is a
hand-written recursive descent parser.

I want to target this at server side applications, so the parser eliminates some nice stuff for humans (namely line / column information, and it throws away comments).

Right now this code:

1. Doesn't know how to execute anything.  It just gives you an AST
2. Isn't used anywhere (except in your heart, *but hopefully in production someday!)

## Usage

You can get an AST like this:

```ruby
ast = TinyGQL.parse "{ cool }"
```

`TinyGQL.parse` accepts any GraphQL document, including schemas.  If you only
want to accept queries, use `TinyGQL::ExecutableParser`, which parses
operations and fragments and raises on type system definitions:

```ruby
ast = TinyGQL::ExecutableParser.parse "{ cool }"
```

The AST is iterable, so you can use the each method:

```ruby
ast = TinyGQL.parse "{ cool }"
ast.each do |node|
  p node.class
end
```

Nodes have predicate methods, so if you want to find particular nodes just use a predicate:

```ruby
ast = TinyGQL.parse "{ cool }"
p ast.find_all(&:field?).map(&:name) # => ["cool"]
```

If you need a more advanced way to iterate nodes, you can use a visitor:

```ruby
class Viz
  include TinyGQL::Visitors::Visitor

  def handle_field obj
    p obj.name # => cool
    super
  end
end

ast = TinyGQL.parse "{ cool }"
ast.accept(Viz.new)
```

If you would like a functional way to collect data from the tree, use the `Fold` module:

```ruby
module Fold
  extend TinyGQL::Visitors::Fold

  def self.handle_field obj, seed
    super(obj, seed + [obj.name])
  end
end

ast = TinyGQL.parse "{ neat { cool } }"
p ast.fold(Fold, []) # => ["neat", "cool"]
```

Nodes store their position in the source GraphQL document.
If you'd like to extract the line number of the node, you'll need to keep a reference to the document and pass it to the `line` method on the node:

```ruby
doc = <<-eod
mutation {
  likeStory(sturyID: 12345) {
    story {
      likeCount
    }
  }
}

eod

parser = TinyGQL::Parser.new doc
ast = parser.parse

ast.find_all(&:field?).each { |node|
  p node.name => node.line(doc)
}
```

## Limiting document size

Fragments can spread other fragments more than once, so a small document can
expand to a huge one.  `TinyGQL::Expansion` measures the expanded size without
expanding anything, and raises if it's over a limit:

```ruby
ast = TinyGQL.parse "{ ...F ...F } fragment F on Query { id }"
TinyGQL::Expansion.check(ast, 100_000).value # => 9
TinyGQL::Expansion.check(ast, 8)
# => TinyGQL::Expansion::LimitExceeded: Maximum expansion limit of 8 exceeded
```

Scores match [Bluejay's](https://github.com/Shopify/bluejay-rb) `max_expansion`
check.  Fragment cycles are cut where they repeat, and `Score#cyclic?` tells you
the document has one.

## Schema-specific parsers

TinyGQL can generate a parser for queries against a particular schema.
The generated parser builds the same AST as `TinyGQL.parse`, but it also
checks each query against the schema while parsing:

```ruby
require "tinygql/generator"

schema = <<~GRAPHQL
  type Query {
    user(id: ID!): User
  }

  type User {
    id: ID!
    name: String
    friends: [User!]!
  }
GRAPHQL

File.write "user_parser.rb", TinyGQL::Generator.new(schema).generate("UserParser")
```

The generated file is plain Ruby, so you can check it in and require it like any other file:

```ruby
require_relative "user_parser"

ast = UserParser.parse "{ user(id: 1) { name friends { name } } }"

# Fields know which type they were selected on
p ast.find_all(&:field?).map { |f| [f.parent_type, f.name] }
# => [["Query", "user"], ["User", "name"], ["User", "friends"], ["User", "name"]]

UserParser.parse "{ user(id: 1) { email } }"
# => TinyGQL::ValidatingParser::ValidationError: Field email does not exist on User line: 1

UserParser.parse "{ user { name } }"
# => TinyGQL::ValidatingParser::ValidationError: Missing required argument id on Query.user line: 1
```

You can also generate a parser from the command line:

```
$ tinygql gen schema.graphql UserParser > user_parser.rb
```

The parser checks that fields and arguments exist, that required arguments
are present, that selection sets are used correctly, and that fragments can
apply where they're spread.  It doesn't check variables, argument value
types, or field merging yet.

## LICENSE:

I've licensed this code as Apache 2.0, but the lexer is from [GraphQL-Ruby](https://github.com/rmosolgo/graphql-ruby/blob/772734dfcc7aa0513c867259912474ef0ba799c3/lib/graphql/language/lexer.rb) and is under the MIT license.
